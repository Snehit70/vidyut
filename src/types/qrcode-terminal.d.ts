declare module "qrcode-terminal" {
  interface GenerateOptions {
    small?: boolean;
  }

  interface QRCodeTerminal {
    generate(value: string, options: GenerateOptions, callback: (qr: string) => void): void;
  }

  const qrcode: QRCodeTerminal;
  export default qrcode;
}

declare module "qrcode-terminal/vendor/QRCode/index.js" {
  const QRCode: unknown;
  export default QRCode;
}

declare module "qrcode-terminal/vendor/QRCode/QRErrorCorrectLevel.js" {
  const levels: unknown;
  export default levels;
}
