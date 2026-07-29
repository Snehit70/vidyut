import { verifyTransferHttpAuth } from "../shared/transfer-http-auth";

export abstract class TransferHttpDataPlane {
  constructor(private readonly pairingSecret: string) {}

  async handle(request: Request): Promise<Response | undefined> {
    if (
      !(await verifyTransferHttpAuth({
        request,
        pairingSecret: this.pairingSecret,
      }))
    ) {
      return Response.json(
        { code: "transfer_auth_failed" },
        { status: 401 },
      );
    }
    return this.handleAuthenticated(request);
  }

  protected abstract handleAuthenticated(
    request: Request,
  ): Promise<Response | undefined>;
}

