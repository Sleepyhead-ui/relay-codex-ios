const stableConnectionResetMs = 10_000;

function reconnectDelayMs(attempt) {
  const boundedAttempt = Math.max(1, Number.isFinite(Number(attempt)) ? Number(attempt) : 1);
  return Math.min(800 * Math.pow(1.7, boundedAttempt - 1), 8_000);
}

module.exports = { reconnectDelayMs, stableConnectionResetMs };
