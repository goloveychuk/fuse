'use strict';

// Minimal stub for es-toolkit/compat used by @yarnpkg/core
function isEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== 'object' || typeof b !== 'object' || a == null || b == null) return false;
  const keysA = Object.keys(a);
  const keysB = Object.keys(b);
  if (keysA.length !== keysB.length) return false;
  for (const key of keysA) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!isEqual(a[key], b[key])) return false;
  }
  return true;
}

function mergeWith(object, ...sources) {
  let customizer;
  if (typeof sources[sources.length - 1] === 'function') {
    customizer = sources.pop();
  }
  for (const source of sources) {
    for (const key of Object.keys(source ?? {})) {
      const customResult = customizer ? customizer(object[key], source[key], key, object, source) : undefined;
      object[key] = customResult !== undefined ? customResult : source[key];
    }
  }
  return object;
}

module.exports = { isEqual, mergeWith };
