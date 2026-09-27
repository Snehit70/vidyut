import qrcode from "qrcode-terminal";
import QRCodeModule from "qrcode-terminal/vendor/QRCode/index.js";
import QRErrorCorrectLevelModule from "qrcode-terminal/vendor/QRCode/QRErrorCorrectLevel.js";

const QRCode = QRCodeModule as unknown as {
  new (typeNumber: number, errorCorrectLevel: number): {
    addData(data: string): void;
    make(): void;
    getModuleCount(): number;
    isDark(row: number, col: number): boolean;
  };
};
const QRErrorCorrectLevel = QRErrorCorrectLevelModule as unknown as {
  M: number;
};

export interface PairingCodeOptions {
  host: string;
  port: number;
  pairingSecret: string;
  relayName?: string;
}

export interface PairingCode {
  raw: string;
  manual: string;
  qr: string;
}

export function pairingPayload(options: PairingCodeOptions): string {
  return JSON.stringify({
    v: 1,
    service: "vidyut",
    host: options.host,
    port: options.port,
    secret: options.pairingSecret,
    ...(options.relayName && { name: options.relayName }),
  });
}

export function pairingManualLine(options: PairingCodeOptions): string {
  return `host=${options.host} port=${options.port} secret=${options.pairingSecret}`;
}

export function createPairingCode(options: PairingCodeOptions): PairingCode {
  const raw = pairingPayload(options);
  return {
    raw,
    manual: pairingManualLine(options),
    qr: renderQr(raw),
  };
}

export function createPairingQrSvg(options: PairingCodeOptions): string {
  return renderQrSvg(pairingPayload(options));
}

function renderQr(value: string): string {
  let output = "";
  qrcode.generate(value, { small: true }, (qr) => {
    output = qr;
  });
  return output;
}

function renderQrSvg(value: string): string {
  const qr = new QRCode(-1, QRErrorCorrectLevel.M);
  qr.addData(value);
  qr.make();
  const count = qr.getModuleCount();
  const quiet = 4;
  const size = count + quiet * 2;
  const modules: string[] = [];
  for (let row = 0; row < count; row += 1) {
    for (let col = 0; col < count; col += 1) {
      if (qr.isDark(row, col)) {
        modules.push(`M${col + quiet} ${row + quiet}h1v1h-1z`);
      }
    }
  }
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges" role="img" aria-label="Vidyut pairing QR">
  <rect width="100%" height="100%" fill="#ffffff"/>
  <path fill="#33202B" d="${modules.join("")}"/>
</svg>
`;
}
