export type ConfigSyncCallbacks = {
  onError?: (error: unknown) => void | Promise<void>;
  onSuccess?: () => void | Promise<void>;
};

/**
 * Runs configuration compilation and its optional continuation as one result.
 * Callers such as the tray must know whether compilation really succeeded;
 * swallowing the error would let them start sing-box with an older config.
 */
export async function runConfigSync(
  compile: () => Promise<void>,
  callbacks: ConfigSyncCallbacks,
): Promise<boolean> {
  try {
    await compile();
    await callbacks.onSuccess?.();
    return true;
  } catch (error) {
    await callbacks.onError?.(error);
    return false;
  }
}
