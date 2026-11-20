const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

// The SDK under test is the parent directory, linked as `file:..`. Metro must watch it, and
// must resolve react/react-native from this app only, never from the SDK's own node_modules.
const sdkRoot = path.resolve(__dirname, '..');

const config = {
  watchFolders: [sdkRoot],
  resolver: {
    nodeModulesPaths: [path.resolve(__dirname, 'node_modules')],
    blockList: [new RegExp(`^${sdkRoot.replace(/[/\\^$.*+?()[\]{}|]/g, '\\$&')}/node_modules/.*`)],
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
