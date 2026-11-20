// The SDK test harness: one button per SDK call and a log of what came back. `e2e/android.mjs`
// taps these buttons by accessibilityLabel, waits for each `[e2e] <button>: ok|error` log line,
// and checks what reached `e2e/fake-kirora.mjs`: keep the labels and the log format.
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { Kirora, SDK_VERSION, type KiroraOptions } from '@kirora/react-native';
import { API_URL, CLIENT_KEY, TOKENS } from './src/config';

type Log = (line: string) => void;

/** The token `fetchUserToken` answers with; the harness changes it to simulate the app's session. */
let sessionToken: string | null = TOKENS.userA;

function makeOptions(log: Log, extra: Partial<KiroraOptions> = {}): KiroraOptions {
  return {
    clientKey: CLIENT_KEY,
    apiUrl: API_URL,
    logLevel: 'debug',
    trackAppLifecycle: true,
    push: {
      defaultChannelId: 'e2e_default',
      defaultChannelName: 'E2E notifications',
      onForegroundNotification: (data) => {
        log(`foreground: ${JSON.stringify(data)}`);
        return data.e2e_hide !== 'true';
      }
    },
    fetchUserToken: async () => {
      log(`fetchUserToken -> ${sessionToken ?? 'null'}`);
      return sessionToken;
    },
    onAuthenticationFailed: (reason) => log(`authFailed: ${reason}`),
    beforeSend: (event) => {
      if (event.name === 'E2E Dropped') return null;
      // Copy, then delete: Babel's object rest (`{ email, ...rest }`) turns a `__proto__` key
      // into a prototype, and the SDK drops an answer that isn't a plain object.
      const properties = { ...event.properties };
      delete properties.email;
      return { ...event, properties };
    },
    handleDeepLink: (url) => {
      log(`deepLink: ${url}`);
      return url.startsWith('kiroraexample://');
    },
    ...extra
  };
}

function describeError(e: unknown): string {
  if (e instanceof Error) return `${e.name}: ${e.message}`;
  return String(e);
}

export default function App() {
  const [lines, setLines] = useState<string[]>([]);
  const [available, setAvailable] = useState<boolean | null>(null);
  const client = useRef<Kirora | null>(null);
  const unsubscribe = useRef<Array<() => void>>([]);

  const log = useCallback<Log>((line) => {
    console.log(`[e2e] ${line}`);
    setLines((prev) => [...prev, line]);
  }, []);

  const start = useCallback(
    (extra: Partial<KiroraOptions> = {}, label = 'start') => {
      unsubscribe.current.forEach((u) => u());
      const k = new Kirora(makeOptions(log, extra));
      client.current = k;
      unsubscribe.current = [
        k.onNotificationClicked((d) => log(`clicked: ${JSON.stringify(d)}`)),
        k.onNotificationReceived((d) => log(`received: ${JSON.stringify(d)}`))
      ];
      setAvailable(k.isAvailable);
      log(`${label}: ok available=${k.isAvailable}`);
      return k;
    },
    [log]
  );

  useEffect(() => {
    log(`sdk ${SDK_VERSION}, api ${API_URL}`);
  }, [log]);

  /** Runs an SDK call and logs `name: ok [result]` or `name: error ...`, for the flows to wait on. */
  const run = useCallback(
    (name: string, call: (k: Kirora) => unknown) => async () => {
      const k = client.current;
      if (!k) return log(`${name}: error no client`);
      try {
        const result = await call(k);
        log(`${name}: ok${result === undefined ? '' : ` ${JSON.stringify(result)}`}`);
      } catch (e) {
        log(`${name}: error ${describeError(e)}`);
      }
    },
    [log]
  );

  const actions: Array<[string, () => unknown]> = [
    ['start', () => start()],
    ['startConsent', () => start({ requireTrackingConsent: true }, 'startConsent')],
    ['identifyA', run('identifyA', (k) => k.identify(TOKENS.userA))],
    ['identifyB', run('identifyB', (k) => k.identify(TOKENS.userB))],
    ['identifyFetch', run('identifyFetch', (k) => k.identify())],
    ['identifyRefused', run('identifyRefused', (k) => k.identify(TOKENS.refused))],
    ['sessionRefused', () => { sessionToken = TOKENS.refused; log('sessionRefused: ok'); }],
    ['sessionNone', () => { sessionToken = null; log('sessionNone: ok'); }],
    ['sessionA', () => { sessionToken = TOKENS.userA; log('sessionA: ok'); }],
    ['logout', run('logout', (k) => k.logout())],
    ['track', run('track', (k) => k.track('E2E Tapped', { n: 1, ok: true, nested: { list: [1, 'two', null] }, email: 'x@example.com' }))],
    ['trackProto', run('trackProto', (k) => k.track('E2E Proto', JSON.parse('{"__proto__":{"tier":"gold"},"order_id":"ORD-1042"}')))],
    ['trackDropped', run('trackDropped', (k) => k.track('E2E Dropped', { secret: true }))],
    ['trackScreen', run('trackScreen', (k) => k.trackScreenView('E2E Screen'))],
    ['consentOn', run('consentOn', (k) => k.setTrackingConsent(true))],
    ['consentOff', run('consentOff', (k) => k.setTrackingConsent(false))],
    ['pushConsentOn', run('pushConsentOn', (k) => k.setPushConsent(true))],
    ['pushConsentOff', run('pushConsentOff', (k) => k.setPushConsent(false))],
    ['requestPermission', run('requestPermission', (k) => k.requestPushPermission())],
    ['pushStatus', run('pushStatus', (k) => k.getPushStatus())],
    ['pushEnabledOn', run('pushEnabledOn', (k) => k.setPushEnabled(true))],
    ['pushEnabledOff', run('pushEnabledOff', (k) => k.setPushEnabled(false))],
    ['flush', run('flush', (k) => k.flush())],
    ['state', run('state', (k) => k.getState())],
    ['destroy', run('destroy', (k) => { k.destroy(); client.current = null; })],
    // A refusal followed at once by a replacement client must still reach native.
    ['replaceAfterRefusal', run('replaceAfterRefusal', (k) => { k.setTrackingConsent(false); start({}, 'replaced'); })],
    ['clearLog', () => setLines([])]
  ];

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.root}>
        <Text testID="available" style={styles.header}>
          available: {available === null ? 'not started' : String(available)}
        </Text>
        <View style={styles.buttons}>
          {actions.map(([id, action]) => (
            <Pressable key={id} testID={id} accessibilityLabel={id} onPress={() => void action()} style={styles.button}>
              <Text style={styles.buttonText}>{id}</Text>
            </Pressable>
          ))}
        </View>
        <Text testID="lastLine" style={styles.last} numberOfLines={3}>
          {lines[lines.length - 1] ?? ''}
        </Text>
        <ScrollView style={styles.log} testID="log">
          {lines.map((line, i) => (
            <Text key={i} style={styles.line}>{line}</Text>
          ))}
        </ScrollView>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#fff', padding: 8 },
  header: { fontWeight: '600', marginBottom: 6, color: '#111' },
  buttons: { flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
  button: { backgroundColor: '#1f4bd8', paddingHorizontal: 8, paddingVertical: 6, borderRadius: 4 },
  buttonText: { color: '#fff', fontSize: 11 },
  last: { marginVertical: 6, fontWeight: '600', color: '#111' },
  log: { flex: 1, borderTopWidth: 1, borderColor: '#ddd' },
  line: { fontSize: 11, fontFamily: 'monospace', color: '#333' }
});
