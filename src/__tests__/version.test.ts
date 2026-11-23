import { SDK_VERSION } from '../version';

test('SDK_VERSION, sent in the Kirora-SDK header, is the package version', () => {
  expect(SDK_VERSION).toBe(require('../../package.json').version);
});
