import test from 'node:test';
import assert from 'node:assert/strict';

import {
  IDLE_FRAME_INTERVAL_MS,
  SLOW_FRAME_INTERVAL_MS,
  TIER_RENDER,
  createRenderGovernor,
  idleBudgetFor,
  renderBudgetForTier,
  shouldRenderFrame,
} from '../../assets/avatar_viewer/rig_device_tier.mjs';

test('the tier only picks the canvas resolution, never the frame rate', () => {
  assert.deepEqual(renderBudgetForTier('bajo'), {frameIntervalMs: 1000 / 60, pixelRatio: .75});
  assert.deepEqual(renderBudgetForTier('medio'), {frameIntervalMs: 1000 / 60, pixelRatio: 1});
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

test('frame skipping hits 60 fps on every tier on 60 and 120 Hz displays', () => {
  assert.equal(renders('medio', 60), 60);
  assert.equal(renders('bajo', 120), 60);
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

// Render con entrada en vivo: un tick de t ms por frame dibujado.
function rendersConGobernador(tier, tickMs, hz = 60, seconds = 4) {
  const gov = createRenderGovernor();
  const budget = renderBudgetForTier(tier);
  let last = 0;
  const porSegundo = [];
  let n = 0;
  for (let i = 1; i <= hz * seconds; i++) {
    const t = i * 1000 / hz;
    if (shouldRenderFrame(last, t, gov.budgetFor(budget))) {
      last = t;
      n++;
      gov.tick(tickMs);
    }
    if (i % hz === 0) { porSegundo.push(n); n = 0; }
  }
  return porSegundo;
}

test('live input renders at display rate on any tier while the own tick fits the frame', () => {
  // Medido en el S22+: tick 5 ms p50, 10-14 ms p95 aun con el tier en medio.
  for (const tier of ['bajo', 'medio', 'alto']) {
    assert.equal(rendersConGobernador(tier, 5).at(-1), 60, tier);
    assert.equal(rendersConGobernador(tier, 14).at(-1), 60, tier);
  }
});

test('only the own measured tick cost slows the render, with hysteresis', () => {
  assert.equal(rendersConGobernador('alto', 20).at(-1), 30);
  const gov = createRenderGovernor();
  for (let i = 0; i < 60; i++) gov.tick(20);
  assert.equal(gov.lento, true);
  assert.equal(gov.budgetFor(TIER_RENDER.alto).frameIntervalMs, SLOW_FRAME_INTERVAL_MS);
  assert.equal(gov.budgetFor(TIER_RENDER.alto).pixelRatio, TIER_RENDER.alto.pixelRatio);
  for (let i = 0; i < 60; i++) gov.tick(14); // entre 12 y 16: sigue lento
  assert.equal(gov.lento, true);
  for (let i = 0; i < 60; i++) gov.tick(6);
  assert.equal(gov.lento, false);
  assert.equal(gov.budgetFor(TIER_RENDER.alto), TIER_RENDER.alto);
});

test('a few slow ticks do not slow the render (p95, not max)', () => {
  const gov = createRenderGovernor();
  for (let i = 0; i < 120; i++) gov.tick(i % 30 === 0 ? 40 : 5);
  assert.equal(gov.lento, false);
});
