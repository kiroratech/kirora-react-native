package io.kirora.reactnative

import android.graphics.Color
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.kirora.androidsdk.Kirora
import com.kirora.androidsdk.KiroraInternalApi
import com.kirora.androidsdk.model.AuthFailureReason
import com.kirora.androidsdk.model.KiroraApiError
import com.kirora.androidsdk.model.KiroraOptions
import com.kirora.androidsdk.model.KiroraPushOptions
import com.kirora.androidsdk.model.LogLevel
import com.kirora.androidsdk.model.UserTokenError
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Hands the JavaScript `Kirora` class to the native Kirora Android SDK, which does the work. The
 * app's callbacks stay in JavaScript and are asked across the bridge: `fetchUserToken` with a
 * `KiroraTokenRequest` event (answered through [resolveToken]), `handleDeepLink` and
 * `onForegroundNotification` with `KiroraDeepLink` and `KiroraForegroundNotification` (answered
 * through [resolveAnswer]; the SDK waits 1.5 s, then acts as if there were
 * no callback). `beforeSend` runs in JavaScript before [track] is called.
 */
@OptIn(KiroraInternalApi::class)
class KiroraSdkModule(
    private val reactContext: ReactApplicationContext,
    /** Makes the maps sent to JavaScript; unit tests pass `::JavaOnlyMap`, which needs no native code. */
    private val newMap: () -> WritableMap = Arguments::createMap
) : ReactContextBaseJavaModule(reactContext) {

    override fun getName() = "KiroraSdk"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val pendingTokens = ConcurrentHashMap<String, CompletableDeferred<String?>>()

    /** Asks waiting for JavaScript's answer: whether a link was opened, or a push is shown. */
    private val pendingAnswers = ConcurrentHashMap<String, CompletableDeferred<Boolean>>()

    /** The current client and the notification events it sends, replaced as a whole by [swapClient]. */
    private class Client(val kirora: Kirora) {
        var clicksOn = false
        var receivedOn = false
    }

    @Volatile
    private var client: Client? = null
    private val kirora: Kirora? get() = client?.kirora

    /** Set by [invalidate]: a set-up still finishing must not install a client after it. */
    private var invalidated = false

    /** JavaScript subscriptions to this module's events: none means nothing would hear one. */
    private val listeners = AtomicInteger(0)

    private val clickListener: (Map<String, String>) -> Unit = { data -> emit(CLICKED_EVENT, data.toWritableMap()) }
    private val receivedListener: (Map<String, String>) -> Unit = { data -> emit(RECEIVED_EVENT, data.toWritableMap()) }

    @ReactMethod
    fun configure(options: ReadableMap, promise: Promise) {
        // The client before stops first: JavaScript sends calls without waiting for the answer, so
        // after a failed set-up they reach no client. The new one starts with no notification
        // events: its JavaScript turns on what it listens for, and the SDK holds taps until then.
        swapClient(null)
        try {
            val provider: (suspend () -> String?)? =
                if (options.getBoolean("hasTokenProvider")) ({ requestToken() }) else null
            val push = if (options.getBoolean("push")) pushOptions(options) else null
            options.stringOrNull("sdkVersion")?.let { Kirora.setWrapperSdk(SDK_NAME, it) }
            // Process-wide in the SDK, so they also hold for a push that arrives before JavaScript
            // has set Kirora up. The blocking native hook would take precedence, so it stays unset.
            Kirora.setForegroundNotificationHandler(null)
            val deepLink: (suspend (String) -> Boolean)? =
                if (options.flag("hasDeepLinkHandler")) ({ url -> ask(DEEP_LINK_EVENT, false) { putString("url", url) } }) else null
            val foreground: (suspend (Map<String, String>) -> Boolean)? =
                if (options.flag("hasForegroundHandler")) ({ data -> ask(FOREGROUND_EVENT, true) { putMap("data", data.toWritableMap()) } }) else null
            if (!setWrapperCallbacks(deepLink, foreground)) return promise.reject("KIRORA_ERROR", "Kirora was stopped")
            val kirora = Kirora(
                reactContext.applicationContext,
                KiroraOptions(
                    clientKey = options.stringOrNull("clientKey") ?: "",
                    fetchUserToken = provider,
                    onAuthenticationFailed = if (options.flag("hasAuthenticationFailedHandler")) ::authenticationFailed else null,
                    push = push,
                    requireTrackingConsent = options.getBoolean("requireTrackingConsent"),
                    trackSessions = options.getBoolean("trackSessions"),
                    trackAppLifecycle = options.getBoolean("trackAppLifecycle"),
                    logLevel = when (options.stringOrNull("logLevel")) {
                        "none" -> LogLevel.NONE
                        "debug" -> LogLevel.DEBUG
                        else -> LogLevel.ERROR
                    },
                    apiUrl = options.stringOrNull("apiUrl") ?: "https://api.kirora.io"
                )
            )
            if (!swapClient(kirora)) {
                kirora.destroy()
                return promise.reject("KIRORA_ERROR", "Kirora was stopped")
            }
            // Whether tracking is allowed now, so JavaScript's beforeSend never sees an event it isn't.
            promise.resolve(newMap().apply { putBoolean("trackingConsent", kirora.trackingConsent) })
        } catch (e: Exception) {
            promise.reject("CONFIGURE_ERROR", e.message, e)
        }
    }

    @ReactMethod
    fun identify(token: String?, promise: Promise) = withKirora(promise) { kirora ->
        kirora.identify(token?.takeIf { it.isNotEmpty() })
        promise.resolve(null)
    }

    @ReactMethod
    fun logout(promise: Promise) = withKirora(promise) { kirora ->
        kirora.logout()
        promise.resolve(null)
    }

    @ReactMethod
    fun track(name: String, propertiesJson: String) {
        val properties = try {
            JSONObject(propertiesJson).toMap()
        } catch (_: Exception) {
            null
        }
        kirora?.track(name, properties)
    }

    @ReactMethod
    fun trackScreenView(name: String) {
        kirora?.trackScreenView(name)
    }

    @ReactMethod
    fun setTrackingConsent(granted: Boolean) {
        kirora?.setTrackingConsent(granted)
    }

    /** Resolves once Kirora recorded the choice; rejects, as [identify] does, when it didn't. */
    @ReactMethod
    fun setPushConsent(granted: Boolean, promise: Promise) = withKirora(promise) { kirora ->
        kirora.setPushConsent(granted)
        promise.resolve(null)
    }

    @ReactMethod
    fun requestPushPermission(promise: Promise) = withKirora(promise) { kirora ->
        val caller = reactContext.currentActivity ?: reactContext
        promise.resolve(kirora.requestPushPermission(caller).wireValue)
    }

    @ReactMethod
    fun getPushStatus(promise: Promise) = withKirora(promise) { kirora ->
        promise.resolve(kirora.getPushStatus().wireValue)
    }

    @ReactMethod
    fun setPushEnabled(enabled: Boolean, promise: Promise) = withKirora(promise) { kirora ->
        kirora.setPushEnabled(enabled)
        promise.resolve(null)
    }

    /** Stops the client without sending or deleting anything; waiting events stay for the next one. */
    @ReactMethod
    fun destroy() {
        // After invalidate, the callbacks are the next context's (or "detached"): left alone.
        setWrapperCallbacks(null, null)
        swapClient(null)
    }

    /**
     * Points the SDK's process-wide link and foreground callbacks here; false, setting nothing, once
     * [invalidate] has run. Locked with it, so callbacks set by a set-up that is still finishing are
     * either replaced by its detach or never set.
     */
    @Synchronized
    private fun setWrapperCallbacks(
        deepLink: (suspend (String) -> Boolean)?,
        foreground: (suspend (Map<String, String>) -> Boolean)?
    ): Boolean {
        if (invalidated) return false
        Kirora.setWrapperCallbacks(deepLink, foreground)
        return true
    }

    /**
     * Stops the current client (its listeners off, then destroyed) and installs [next], or none.
     * False, installing nothing, once [invalidate] has run. Under the same lock as
     * [setNotificationEvents]: a reload's [invalidate] runs on another thread than JavaScript's calls.
     */
    @Synchronized
    private fun swapClient(next: Kirora?): Boolean {
        if (next != null && invalidated) return false
        client?.let { old ->
            if (old.clicksOn) old.kirora.removeNotificationClickListener(clickListener)
            if (old.receivedOn) old.kirora.removeForegroundNotificationListener(receivedListener)
            old.kirora.destroy()
        }
        client = next?.let(::Client)
        return true
    }

    @ReactMethod
    fun flush(promise: Promise) = withKirora(promise) { kirora ->
        kirora.flush()
        promise.resolve(null)
    }

    @ReactMethod
    fun getState(promise: Promise) {
        // The SDK's own snapshot: it reads safely and counts every waiting event, on disk and in
        // memory. Null (the empty state, in JavaScript) when there is no client or it can't be read.
        val kirora = kirora ?: return promise.resolve(null)
        scope.launch {
            val state = try {
                kirora.getState()
            } catch (e: CancellationException) {
                promise.resolve(null)
                throw e
            } catch (_: Exception) {
                return@launch promise.resolve(null)
            }
            promise.resolve(newMap().apply {
                putBoolean("isInitialized", state.isInitialized)
                putBoolean("isIdentified", state.isIdentified)
                putString("deviceId", state.deviceId)
                putString("sessionId", state.sessionId)
                putString("pushToken", state.pushToken)
                putBoolean("trackingConsent", state.trackingConsent)
                putBoolean("pushConsent", state.pushConsent)
                putInt("queuedEventCount", state.queuedEventCount)
            })
        }
    }

    /** Starts or stops the `KiroraNotificationClicked` / `KiroraNotificationReceived` events. */
    @Synchronized
    @ReactMethod
    fun setNotificationEvents(clicked: Boolean, received: Boolean) {
        val client = client ?: return
        val kirora = client.kirora
        if (clicked != client.clicksOn) {
            client.clicksOn = clicked
            // Attaching delivers a tap that launched the app before JavaScript was listening.
            if (clicked) kirora.addNotificationClickListener(clickListener) else kirora.removeNotificationClickListener(clickListener)
        }
        if (received != client.receivedOn) {
            client.receivedOn = received
            if (received) kirora.addForegroundNotificationListener(receivedListener) else kirora.removeForegroundNotificationListener(receivedListener)
        }
    }

    /** Answers [ask]: whether a link was opened, or a push is shown. */
    @ReactMethod
    fun resolveAnswer(requestId: String, answer: Boolean) {
        pendingAnswers.remove(requestId)?.complete(answer)
    }

    @ReactMethod
    fun onNewPushToken(token: String) {
        kirora?.onNewPushToken(token)
    }

    @ReactMethod
    fun onPushRegistered(installationId: String) {
        kirora?.onPushRegistered(installationId)
    }

    @ReactMethod
    fun resolveToken(requestId: String, token: String?, error: String?) {
        val pending = pendingTokens[requestId] ?: return
        if (error == null && !token.isNullOrEmpty()) {
            pending.complete(token)
        } else {
            pending.completeExceptionally(IllegalStateException(error ?: "fetchUserToken returned no token"))
        }
    }

    // NativeEventEmitter calls these when JavaScript starts and stops listening.
    @ReactMethod
    fun addListener(eventName: String) {
        listeners.incrementAndGet()
    }

    @ReactMethod
    fun removeListeners(count: Double) {
        listeners.updateAndGet { maxOf(0, it - count.toInt()) }
    }

    override fun invalidate() {
        pendingTokens.values.forEach { it.cancel() }
        pendingTokens.clear()
        pendingAnswers.values.forEach { it.cancel() }
        pendingAnswers.clear()
        // No JavaScript behind it any more (reload): stop it, as iOS does, and refuse a set-up
        // still finishing (see [setWrapperCallbacks] and [swapClient], locked with this).
        synchronized(this) {
            invalidated = true
            // Not "set up with no handler": the next JavaScript context may set one, so a tap's
            // link waits for it again (10 s at most) instead of opening at once.
            Kirora.wrapperDetached()
            swapClient(null)
        }
        scope.cancel()
        super.invalidate()
    }

    private suspend fun requestToken(): String? {
        val id = UUID.randomUUID().toString()
        val answer = CompletableDeferred<String?>()
        pendingTokens[id] = answer
        try {
            if (!emit(TOKEN_REQUEST_EVENT, newMap().apply { putString("requestId", id) })) {
                throw IllegalStateException("No fetchUserToken is listening")
            }
            // A plain exception, not a cancellation, so the SDK reports it as a UserTokenError.
            return withTimeoutOrNull(TOKEN_TIMEOUT_MS) { answer.await() }
                ?: throw IllegalStateException("fetchUserToken got no answer within ${TOKEN_TIMEOUT_MS / 1000} seconds")
        } finally {
            pendingTokens.remove(id)
        }
    }

    /**
     * Sends [event] and waits for JavaScript's answer, at most as long as the SDK does: [fallback]
     * without one in time. The SDK applies the same fallback when it stops waiting.
     */
    private suspend fun ask(event: String, fallback: Boolean, body: WritableMap.() -> Unit): Boolean {
        val id = UUID.randomUUID().toString()
        val answer = CompletableDeferred<Boolean>()
        pendingAnswers[id] = answer
        return try {
            val sent = emit(event, newMap().apply {
                putString("requestId", id)
                // When this ask stops waiting: JavaScript doesn't run the app's callback after it,
                // since the fallback has acted by then (a link already opened, say).
                putDouble("expiresAt", (System.currentTimeMillis() + ANSWER_TIMEOUT_MS).toDouble())
                body()
            })
            if (!sent) return fallback
            withTimeoutOrNull(ANSWER_TIMEOUT_MS) { answer.await() } ?: fallback
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            fallback
        } finally {
            pendingAnswers.remove(id)
        }
    }

    private fun authenticationFailed(reason: AuthFailureReason) {
        val wire = when (reason) {
            AuthFailureReason.FETCH_FAILED -> "fetch_failed"
            AuthFailureReason.REFUSED -> "refused"
        }
        emit(AUTHENTICATION_FAILED_EVENT, newMap().apply { putString("reason", wire) })
    }

    /**
     * Sends [event] to JavaScript: false, sending nothing, when nothing listens or there is no
     * live React instance (a reload, a teardown), as iOS skips them.
     */
    private fun emit(event: String, params: Any?): Boolean {
        if (listeners.get() == 0 || !reactContext.hasActiveReactInstance()) return false
        return try {
            reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java).emit(event, params)
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun pushOptions(options: ReadableMap): KiroraPushOptions {
        val resources = reactContext.resources
        val pkg = reactContext.packageName
        val icon = options.stringOrNull("smallIcon")?.let { name ->
            resources.getIdentifier(name, "drawable", pkg).takeIf { it != 0 }
                ?: resources.getIdentifier(name, "mipmap", pkg).takeIf { it != 0 }
        }
        val color = options.stringOrNull("accentColor")?.let {
            try {
                Color.parseColor(it)
            } catch (_: IllegalArgumentException) {
                null
            }
        }
        return KiroraPushOptions(
            pushAppId = options.stringOrNull("pushAppId"),
            smallIconResId = icon,
            accentColor = color,
            defaultChannelId = options.stringOrNull("defaultChannelId") ?: "kirora_default",
            defaultChannelName = options.stringOrNull("defaultChannelName") ?: "Notifications"
        )
    }

    private fun Map<String, String>.toWritableMap() = newMap().also { map ->
        forEach { (k, v) -> map.putString(k, v) }
    }

    private fun withKirora(promise: Promise, block: suspend (Kirora) -> Unit) {
        val kirora = kirora
        if (kirora == null) {
            promise.reject("NOT_CONFIGURED", "Kirora was not set up")
            return
        }
        scope.launch {
            try {
                block(kirora)
            } catch (e: CancellationException) {
                // The module is going away (reload): settle the promise rather than leave it hanging.
                promise.reject("KIRORA_ERROR", "Kirora was stopped", e)
                throw e
            } catch (e: Exception) {
                reject(promise, e)
            }
        }
    }

    /**
     * Rejects with the codes `errorFromNative` (NativeBackend.ts) maps to the SDK's errors:
     * `USER_TOKEN_ERROR`, `KIRORA_API_ERROR` with `status`, `code` and `retryAfterMs` in `userInfo`,
     * and `KIRORA_ERROR` for a setup or network problem.
     */
    private fun reject(promise: Promise, e: Exception) {
        when (e) {
            is UserTokenError -> promise.reject("USER_TOKEN_ERROR", e.message, e)
            is KiroraApiError -> promise.reject("KIRORA_API_ERROR", e.message, e, newMap().apply {
                putInt("status", e.status)
                if (e.code != null) putString("code", e.code) else putNull("code")
                val retryAfter = e.retryAfterMs
                if (retryAfter != null) putDouble("retryAfterMs", retryAfter.toDouble()) else putNull("retryAfterMs")
            })
            else -> promise.reject("KIRORA_ERROR", e.message, e)
        }
    }

    private fun ReadableMap.stringOrNull(key: String): String? = if (hasKey(key) && !isNull(key)) getString(key) else null

    private fun ReadableMap.flag(key: String): Boolean = hasKey(key) && !isNull(key) && getBoolean(key)

    private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { unwrap(get(it)) }

    private fun unwrap(value: Any?): Any? = when {
        value == null || value == JSONObject.NULL -> null
        value is JSONObject -> value.toMap()
        value is JSONArray -> (0 until value.length()).map { unwrap(value.get(it)) }
        else -> value
    }

    private companion object {
        const val TOKEN_REQUEST_EVENT = "KiroraTokenRequest"
        const val FOREGROUND_EVENT = "KiroraForegroundNotification"
        const val DEEP_LINK_EVENT = "KiroraDeepLink"
        const val CLICKED_EVENT = "KiroraNotificationClicked"
        const val RECEIVED_EVENT = "KiroraNotificationReceived"
        const val AUTHENTICATION_FAILED_EVENT = "KiroraAuthenticationFailed"
        const val TOKEN_TIMEOUT_MS = 30_000L
        const val ANSWER_TIMEOUT_MS = 1_500L
        const val SDK_NAME = "kirora-react-native"
    }
}
