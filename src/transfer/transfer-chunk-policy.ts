export const legacyTransferChunkBytes = 256 * 1024;
export const preferredTransferChunkBytes = 1024 * 1024;

export function negotiateTransferChunkBytes(
  advertisedBytes: number | undefined,
  localMaximum: number,
): number {
  if (
    advertisedBytes === undefined ||
    !Number.isSafeInteger(advertisedBytes) ||
    advertisedBytes <= 0
  ) {
    return Math.min(localMaximum, legacyTransferChunkBytes);
  }
  return Math.min(localMaximum, advertisedBytes);
}
