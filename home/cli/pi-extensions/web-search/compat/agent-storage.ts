/**
 * `AgentStorage` stub. omp's real implementation persists OAuth tokens
 * and cached API keys via bun:sqlite. This fork has no equivalent;
 * provider helpers (`findCredential`, `findOAuthToken`) short-circuit
 * on null returns and fall through to env-var auth instead. All
 * operations on this stub are no-ops.
 */
export class AgentStorage {
  private static singleton: AgentStorage | undefined;

  static get(): AgentStorage {
    AgentStorage.singleton ??= new AgentStorage();
    return AgentStorage.singleton;
  }

  /** Mirrors omp's path-keyed open(). We ignore the path — there is no
   * persistent store. */
  static async open(_path: string): Promise<AgentStorage> {
    return AgentStorage.get();
  }

  /** Always empty; callers fall through to env-var auth. */
  listAuthCredentials(_provider: string): AuthCredentialRecord[] {
    return [];
  }

  async getCredential(_provider: string): Promise<undefined> { return undefined; }
  async setCredential(_provider: string, _value: unknown): Promise<void> { /* no-op */ }
  async deleteCredential(_provider: string): Promise<void> { /* no-op */ }
}

export interface AuthCredentialRecord {
  credential:
    | { type: "api_key"; key: string }
    | { type: "oauth"; access: string; refresh?: string; expires?: number };
}
