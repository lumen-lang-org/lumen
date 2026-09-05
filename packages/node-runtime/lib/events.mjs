// `EventEmitter<T>` (spec 043): every event on one emitter carries a payload
// of the same type. Listeners run in registration order; a `once` listener is
// dropped after the emit that called it; `removeAllListeners()` clears every
// name and `removeAllListeners(name)` one name.
export class EventEmitter {
  #listeners = new Map();

  #add(name, listener, once) {
    let list = this.#listeners.get(name);
    if (!list) { list = []; this.#listeners.set(name, list); }
    list.push({ fn: listener, once });
  }

  on(name, listener) {
    this.#add(name, listener, false);
  }

  once(name, listener) {
    this.#add(name, listener, true);
  }

  emit(name, value) {
    const list = this.#listeners.get(name);
    if (!list) return;
    let hasOnce = false;
    for (const l of list.slice()) {
      l.fn(value);
      if (l.once) hasOnce = true;
    }
    if (hasOnce) this.#listeners.set(name, list.filter((l) => !l.once));
  }

  removeAllListeners(name) {
    if (name === undefined) { for (const list of this.#listeners.values()) list.length = 0; return; }
    this.removeListenersFor(name);
  }

  removeListenersFor(name) {
    const list = this.#listeners.get(name);
    if (list) list.length = 0;
  }

  listenerCount(name) {
    const list = this.#listeners.get(name);
    return list ? list.length : 0;
  }
}
