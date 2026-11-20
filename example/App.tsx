import React, {useCallback, useEffect, useMemo, useState} from 'react';
import {
  Platform,
  Pressable,
  ScrollView,
  StatusBar,
  StyleSheet,
  Switch,
  Text,
  View,
  useColorScheme,
} from 'react-native';
import {SafeAreaProvider, useSafeAreaInsets} from 'react-native-safe-area-context';
import {Kirora, SDK_VERSION, type KiroraState, type PushStatus} from '@kirora/react-native';
import {CONFIG} from './src/config';

// One client for the whole app, created at startup, outside any component.
const kirora = new Kirora({
  clientKey: CONFIG.clientKey,
  apiUrl: CONFIG.apiUrl,
  trackAppLifecycle: true,
  logLevel: 'debug',
  push: CONFIG.pushEnabled ? {pushAppId: CONFIG.pushAppId || undefined} : false,
  // Called when the SDK needs a (fresh) user token. Your backend signs it.
  fetchUserToken: async () => CONFIG.userToken || null,
});

const LIGHT = {bg: '#F2F2F7', card: '#FFFFFF', text: '#111111', muted: '#6B6B73', tint: '#3550D6', line: '#E3E3E8'};
const DARK = {bg: '#000000', card: '#1C1C1E', text: '#FFFFFF', muted: '#98989F', tint: '#8AA2FF', line: '#38383A'};
type Colors = typeof LIGHT;

function Root() {
  const c = useColorScheme() === 'dark' ? DARK : LIGHT;
  const s = useMemo(() => styles(c), [c]);
  const insets = useSafeAreaInsets();

  const [state, setState] = useState<KiroraState | null>(null);
  const [push, setPush] = useState<PushStatus | null>(null);
  const [message, setMessage] = useState('Ready.');
  const [lastPush, setLastPush] = useState<{event: 'Received' | 'Tapped'; data: Record<string, string>} | null>(null);

  const refresh = useCallback(async () => {
    setState(await kirora.getState());
    setPush(await kirora.getPushStatus());
  }, []);

  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, 2000);
    const offReceived = kirora.onNotificationReceived(data => setLastPush({event: 'Received', data}));
    const offClicked = kirora.onNotificationClicked(data => setLastPush({event: 'Tapped', data}));
    return () => {
      clearInterval(timer);
      offReceived();
      offClicked();
    };
  }, [refresh]);

  const run = async (label: string, work: () => unknown) => {
    try {
      const result = await work();
      setMessage(`${label}: ${typeof result === 'string' ? result : 'ok'}`);
    } catch (e) {
      setMessage(`${label}: ${e instanceof Error ? e.message : String(e)}`);
    }
    refresh();
  };

  const signedIn = !!state?.isIdentified;

  return (
    <ScrollView
      style={{backgroundColor: c.bg}}
      contentContainerStyle={{paddingTop: insets.top + 16, paddingBottom: insets.bottom + 32, paddingHorizontal: 16, gap: 24}}>
      <View style={{gap: 4}}>
        <Text style={s.title}>Kirora</Text>
        <Text style={s.muted}>
          React Native SDK {SDK_VERSION} · {CONFIG.apiUrl.replace(/^https?:\/\//, '')}
        </Text>
      </View>

      <Section title="Account" c={c}>
        <Row label="Status" value={signedIn ? 'Signed in' : 'Signed out'} c={c} />
        {signedIn ? (
          <Action label="Sign out" destructive onPress={() => run('Sign out', () => kirora.logout())} c={c} />
        ) : (
          <Action label="Sign in" onPress={() => run('Sign in', () => kirora.identify(CONFIG.userToken))} c={c} />
        )}
      </Section>

      <Section title="Events" c={c}>
        <Action
          label="Track event"
          onPress={() => run('Track event', () => kirora.track('Button Tapped', {screen: 'Home'}))}
          c={c}
        />
        <Action label="Track screen view" onPress={() => run('Screen view', () => kirora.trackScreenView('Home'))} c={c} />
        <Action label="Send queued events now" onPress={() => run('Flush', () => kirora.flush())} c={c} />
        <Row label="Queued" value={String(state?.queuedEventCount ?? 0)} c={c} />
      </Section>

      <Section title="Consent" c={c}>
        <View style={s.row}>
          <Text style={s.label}>Track behaviour</Text>
          <Switch
            value={!!state?.trackingConsent}
            onValueChange={on => run('Tracking consent', () => kirora.setTrackingConsent(on))}
          />
        </View>
      </Section>

      <Section title="Push" c={c}>
        <Row label="Status" value={push ?? '…'} c={c} />
        <Row label="Token" value={state?.pushToken ?? 'none'} c={c} />
        <Action label="Ask for permission" onPress={() => run('Permission', () => kirora.requestPushPermission())} c={c} />
        <View style={s.row}>
          <Text style={s.label}>Marketing messages</Text>
          <Switch
            value={!!state?.pushConsent}
            disabled={!signedIn}
            onValueChange={on => run('Marketing consent', () => kirora.setPushConsent(on))}
          />
        </View>
        {lastPush ? (
          <View style={s.block}>
            <Text style={s.label}>Last notification ({lastPush.event.toLowerCase()})</Text>
            <Text style={s.json} selectable>
              {JSON.stringify(lastPush.data, null, 2)}
            </Text>
          </View>
        ) : null}
        {!CONFIG.pushEnabled ? <Text style={s.note}>Push is off in this build. See README.</Text> : null}
      </Section>

      <Section title="Device" c={c}>
        <Row label="Device ID" value={state?.deviceId ?? '—'} c={c} />
        <Row label="Session ID" value={state?.sessionId ?? '—'} c={c} />
      </Section>

      <Text style={s.muted}>{message}</Text>
    </ScrollView>
  );
}

function Section({title, children, c}: {title: string; children: React.ReactNode; c: Colors}) {
  const s = styles(c);
  return (
    <View style={{gap: 8}}>
      <Text style={s.sectionTitle}>{title}</Text>
      <View style={s.card}>{children}</View>
    </View>
  );
}

function Row({label, value, c}: {label: string; value: string; c: Colors}) {
  const s = styles(c);
  return (
    <View style={s.row}>
      <Text style={s.label}>{label}</Text>
      <Text style={s.value} numberOfLines={1} ellipsizeMode="middle">
        {value}
      </Text>
    </View>
  );
}

function Action({label, onPress, c, destructive}: {label: string; onPress: () => void; c: Colors; destructive?: boolean}) {
  const s = styles(c);
  return (
    <Pressable onPress={onPress} style={({pressed}) => [s.row, pressed && {opacity: 0.5}]} accessibilityRole="button">
      <Text style={[s.label, {color: destructive ? '#D93636' : c.tint, fontWeight: '600'}]}>{label}</Text>
    </Pressable>
  );
}

const styles = (c: Colors) =>
  StyleSheet.create({
    title: {fontSize: 32, fontWeight: '700', color: c.text},
    muted: {fontSize: 13, color: c.muted},
    note: {fontSize: 13, color: c.muted, padding: 14},
    block: {padding: 14, gap: 8},
    json: {fontSize: 12, color: c.muted, fontFamily: Platform.select({ios: 'Menlo', default: 'monospace'})},
    sectionTitle: {fontSize: 13, fontWeight: '600', color: c.muted, textTransform: 'uppercase', marginLeft: 4},
    card: {backgroundColor: c.card, borderRadius: 12, overflow: 'hidden'},
    row: {
      minHeight: 48,
      paddingHorizontal: 14,
      paddingVertical: 10,
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
      gap: 16,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: c.line,
    },
    label: {fontSize: 16, color: c.text},
    value: {fontSize: 16, color: c.muted, flexShrink: 1},
  });

export default function App() {
  const dark = useColorScheme() === 'dark';
  return (
    <SafeAreaProvider>
      <StatusBar barStyle={dark ? 'light-content' : 'dark-content'} />
      <Root />
    </SafeAreaProvider>
  );
}
