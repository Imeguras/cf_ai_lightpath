// Stand-in for the runtime's WorkflowEntrypoint: keeps ctx and env, like the
// real base class does, and nothing else.
export class WorkflowEntrypoint<Env = unknown, _Params = unknown> {
  ctx: unknown;
  env: Env;
  constructor(ctx: unknown, env: Env) {
    this.ctx = ctx;
    this.env = env;
  }
}
