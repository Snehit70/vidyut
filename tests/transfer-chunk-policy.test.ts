import { describe, expect, test } from "bun:test";
import {
  legacyTransferChunkBytes,
  negotiateTransferChunkBytes,
  preferredTransferChunkBytes,
} from "../src/transfer/transfer-chunk-policy";

describe("transfer chunk policy", () => {
  test("falls back to legacy chunks for peers without negotiation", () => {
    expect(
      negotiateTransferChunkBytes(undefined, preferredTransferChunkBytes),
    ).toBe(legacyTransferChunkBytes);
  });

  test("uses the largest chunk both peers support", () => {
    expect(
      negotiateTransferChunkBytes(
        2 * preferredTransferChunkBytes,
        preferredTransferChunkBytes,
      ),
    ).toBe(preferredTransferChunkBytes);
  });
});
