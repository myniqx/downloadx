/**
 * Zero-dependency, strictly-typed event emitter.
 *
 * Not compatible with Node's `EventEmitter` on purpose — the goal is a minimal,
 * synchronous dispatcher that works identically in every JS runtime.
 *
 * Listeners are dispatched synchronously in registration order. Errors thrown
 * from listeners are caught and reported via {@link TypedEventEmitter.onError}
 * so one bad listener cannot block the rest or crash the download pipeline.
 */
export class TypedEventEmitter<EventMap extends object> {
  private readonly listeners = new Map<
    keyof EventMap,
    Set<(payload: EventMap[keyof EventMap]) => void>
  >();

  /**
   * Optional hook invoked when a listener throws. Defaults to silent.
   * Consumers can override to surface bugs in their handlers.
   */
  public onError: (error: unknown, event: keyof EventMap) => void = () => {
    /* swallow by default */
  };

  on<E extends keyof EventMap>(event: E, listener: (payload: EventMap[E]) => void): () => void {
    let set = this.listeners.get(event);
    if (!set) {
      set = new Set();
      this.listeners.set(event, set);
    }
    set.add(listener as (payload: EventMap[keyof EventMap]) => void);
    return () => this.off(event, listener);
  }

  once<E extends keyof EventMap>(event: E, listener: (payload: EventMap[E]) => void): () => void {
    const wrapper = (payload: EventMap[E]): void => {
      this.off(event, wrapper);
      listener(payload);
    };
    return this.on(event, wrapper);
  }

  off<E extends keyof EventMap>(event: E, listener: (payload: EventMap[E]) => void): void {
    const set = this.listeners.get(event);
    if (!set) return;
    set.delete(listener as (payload: EventMap[keyof EventMap]) => void);
    if (set.size === 0) this.listeners.delete(event);
  }

  emit<E extends keyof EventMap>(event: E, payload: EventMap[E]): void {
    const set = this.listeners.get(event);
    if (!set || set.size === 0) return;
    // Copy the set so listeners that remove themselves during dispatch don't
    // corrupt the iteration.
    const snapshot = Array.from(set);
    for (const listener of snapshot) {
      try {
        (listener as (payload: EventMap[E]) => void)(payload);
      } catch (err) {
        try {
          this.onError(err, event);
        } catch {
          /* never allow onError to throw */
        }
      }
    }
  }

  listenerCount<E extends keyof EventMap>(event: E): number {
    return this.listeners.get(event)?.size ?? 0;
  }

  removeAllListeners<E extends keyof EventMap>(event?: E): void {
    if (event === undefined) {
      this.listeners.clear();
      return;
    }
    this.listeners.delete(event);
  }

  /**
   * Re-emit every event this emitter fires through `target`.
   *
   * Used so that events emitted by a single `Download` are transparently
   * surfaced on the parent `DownloadX` emitter. The returned function tears
   * down the relay.
   */
  pipeTo(target: TypedEventEmitter<EventMap>, events: readonly (keyof EventMap)[]): () => void {
    const disposers: Array<() => void> = [];
    for (const event of events) {
      const dispose = this.on(event, (payload) => {
        target.emit(event, payload);
      });
      disposers.push(dispose);
    }
    return () => {
      for (const d of disposers) d();
    };
  }
}
