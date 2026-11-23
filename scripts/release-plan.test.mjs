// node --test scripts/release-plan.test.mjs
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { registryView, releasePlan } from './release-plan.mjs';

describe('releasePlan', () => {
  const plan = (version, published = [], latest = undefined) => {
    const { publish, distTag } = releasePlan({ version, published, latest });
    return { publish, distTag };
  };

  it('publishes the first release as latest', () => {
    assert.deepEqual(plan('0.1.0'), { publish: true, distTag: 'latest' });
  });

  it('makes the first release latest after the placeholder that created the package', () => {
    assert.deepEqual(plan('0.1.0', ['0.0.1-stage'], undefined), { publish: true, distTag: 'latest' });
    assert.deepEqual(plan('0.1.0', ['0.0.1-stage'], '0.0.1-stage'), { publish: true, distTag: 'latest' });
  });

  it('makes a newer stable release latest', () => {
    assert.deepEqual(plan('1.3.0', ['1.2.0'], '1.2.0'), { publish: true, distTag: 'latest' });
    assert.deepEqual(plan('1.10.0', ['1.9.0'], '1.9.0'), { publish: true, distTag: 'latest' });
  });

  it('never moves latest back for an older maintenance release', () => {
    assert.deepEqual(plan('1.1.5', ['1.1.4', '1.2.0'], '1.2.0'), { publish: true, distTag: 'release-1.1' });
  });

  it('publishes a prerelease to next', () => {
    assert.deepEqual(plan('2.0.0-beta.1', ['1.2.0'], '1.2.0'), { publish: true, distTag: 'next' });
  });

  it('skips a version already on npm', () => {
    assert.deepEqual(plan('1.2.0', ['1.2.0'], '1.2.0'), { publish: false, distTag: undefined });
  });
});

describe('registryView', () => {
  const view = { versions: ['0.1.0', '0.2.0'], 'dist-tags': { latest: '0.2.0' } };
  const expected = { published: ['0.1.0', '0.2.0'], latest: '0.2.0' };

  it('reads npm 11, which answers an object', () => {
    assert.deepEqual(registryView(JSON.stringify(view)), expected);
  });

  it('reads npm 12, which wraps the answer in an array', () => {
    assert.deepEqual(registryView(JSON.stringify([view])), expected);
  });

  it('reads a package with a single version, whose versions npm gives as a string', () => {
    const single = { versions: '0.1.0', 'dist-tags': { latest: '0.1.0' } };
    assert.deepEqual(registryView(JSON.stringify(single)), { published: ['0.1.0'], latest: '0.1.0' });
  });
});
