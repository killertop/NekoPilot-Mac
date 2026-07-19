/**
 * Serializes lifecycle operations while allowing a later user action to run
 * even when an earlier operation fails.
 */
export function createLifecycleQueue() {
  let tail: Promise<void> = Promise.resolve();

  return {
    run<T>(job: () => Promise<T>): Promise<T> {
      const result = tail.then(job, job);
      tail = result.then(
        () => undefined,
        () => undefined,
      );
      return result;
    },
  };
}
