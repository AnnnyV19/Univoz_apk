import test from 'node:test';
import assert from 'node:assert/strict';

import {
  IDLE_FRAME_INTERVAL_MS,
  TIER_RENDER,
  idleBudgetFor,
  renderBudgetForTier,
  shouldRenderFrame,
} from '../../assets/avatar_viewer/rig_device_tier.mjs';

test('render budget per tier matches the spec', () => {
  assert.deepEqual(renderBudgetForTier('bajo'), {frameIntervalMs: 1000 / 30, pixelRatio: .75});
  assert.deepEqual(renderBudgetForTier('medio'), {frameIntervalMs: 1000 / 30, pixelRatio: 1});
  assert.deepEqual(renderBudgetForTier('alto'), {frameIntervalMs: 1000 / 60, pixelRatio: 1.25});
});

test('unknown tier falls back to alto (same object)', () => {
  for (const tier of [null, undefined, '', 'ULTRA', 3, {}]) {
    assert.equal(renderBudgetForTier(tier), TIER_RENDER.alto);
  }
  assert.equal(renderBudgetForTier('bajo'), TIER_RENDER.bajo);
});

function renders(tier, hz, seconds = 1) {
  const budget = renderBudgetForTier(tier);
  let last = 0;
  let n = 0;
  for (let i = 1; i <= hz * seconds; i++) {
    const t = i * 1000 / hz;
    if (shouldRenderFrame(last, t, budget)) {
      last = t;
      n++;
    }
  }
  return n;
}

test('frame skipping hits the tier fps on 60 and 120 Hz displays', () => {
  assert.equal(renders('medio', 60), 30);
  assert.equal(renders('bajo', 120), 30);
  assert.equal(renders('alto', 60), 60);
  assert.equal(renders('alto', 120), 60);
});

test('idle avatar renders at 15 fps on any tier and keeps pixel ratio', () => {
  for (const tier of ['bajo', 'medio', 'alto']) {
    const idle = idleBudgetFor(renderBudgetForTier(tier));
    assert.equal(idle.frameIntervalMs, IDLE_FRAME_INTERVAL_MS);
    assert.equal(idle.pixelRatio, renderBudgetForTier(tier).pixelRatio);
    // Mismo objeto cada vez: animar() lo pide en cada rAF sin crear basura.
    assert.equal(idleBudgetFor(renderBudgetForTier(tier)), idle);
    let last = 0;
    let n = 0;
    for (let i = 1; i <= 120; i++) {
      const t = i * 1000 / 120;
      if (shouldRenderFrame(last, t, idle)) {
        last = t;
        n++;
      }
    }
    assert.equal(n, 15);
  }
});
