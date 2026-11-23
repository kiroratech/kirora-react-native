/** Thrown by `jsonSnapshot` for a value JSON would change or lose. */
export class NotJsonError extends Error {}

/**
 * A deep copy of `value` made only of what JSON holds: plain objects, arrays, strings,
 * finite numbers, booleans and null. Throws `NotJsonError` for anything JSON would change
 * or lose (a function, `NaN`, a `Map`, a circular reference…) rather than send something
 * other than what the app tracked. An object member that is `undefined` is left out, and
 * an object with `toJSON()` (a `Date`) is copied as what that answers, as `JSON.stringify` does.
 */
export function jsonSnapshot(value: unknown): unknown {
  const ancestors = new Set<object>();
  const copy = (item: unknown): unknown => {
    if (item === null || typeof item === 'string' || typeof item === 'boolean') return item;
    if (typeof item === 'number') {
      if (Number.isFinite(item)) return item;
      throw new NotJsonError('a number JSON has no form for');
    }
    if (typeof item !== 'object') throw new NotJsonError(`a value of type ${typeof item}`);
    if (ancestors.has(item)) throw new NotJsonError('a circular reference');
    ancestors.add(item);
    try {
      if (Array.isArray(item)) return Array.from(item, copy);
      const prototype = Object.getPrototypeOf(item) as unknown;
      if (prototype !== Object.prototype && prototype !== null) {
        const { toJSON } = item as { toJSON?: unknown };
        if (typeof toJSON !== 'function') throw new NotJsonError('an object JSON has no form for, such as a Map');
        return copy((toJSON as () => unknown).call(item));
      }
      const copied: Record<string, unknown> = {};
      for (const [key, member] of Object.entries(item)) {
        if (member === undefined) continue;
        // Assigning `__proto__` would set the copy's prototype instead of adding the member.
        if (key === '__proto__') {
          Object.defineProperty(copied, key, { value: copy(member), enumerable: true, writable: true, configurable: true });
        } else {
          copied[key] = copy(member);
        }
      }
      return copied;
    } finally {
      ancestors.delete(item);
    }
  };
  return copy(value);
}

/** Whether `value` is a promise or another thenable. */
export function isThenable(value: unknown): value is PromiseLike<unknown> {
  return typeof (value as PromiseLike<unknown> | null | undefined)?.then === 'function';
}

/** A plain object: not null, an array, or something like a Date. False when a getter it runs throws. */
export function isPlainObject(value: unknown): value is Record<string, unknown> {
  try {
    return Object.prototype.toString.call(value) === '[object Object]';
  } catch {
    return false;
  }
}
