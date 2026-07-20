import type { DelayStatus } from "./node-delay";

/** Orders successful measurements first, then pending nodes, then timeouts. */
export function compareNodesByDelay(
  left: string,
  right: string,
  delays: Record<string, DelayStatus>,
  pendingNodes: Set<string>,
): number {
  const leftDelay = delays[left];
  const rightDelay = delays[right];
  const leftHasDelay = typeof leftDelay === "number";
  const rightHasDelay = typeof rightDelay === "number";

  if (leftHasDelay && rightHasDelay) return leftDelay - rightDelay;
  if (leftHasDelay) return -1;
  if (rightHasDelay) return 1;

  const leftPending = pendingNodes.has(left);
  const rightPending = pendingNodes.has(right);
  if (leftPending !== rightPending) return leftPending ? -1 : 1;
  return 0;
}
