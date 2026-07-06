const TEAM_ID_KEY = "fet-scavenge:team-id";

export function getStoredTeamId(): string | null {
  if (typeof window === "undefined") return null;
  return window.localStorage.getItem(TEAM_ID_KEY);
}

export function storeTeamId(teamId: string) {
  window.localStorage.setItem(TEAM_ID_KEY, teamId);
}

export function clearStoredTeamId() {
  window.localStorage.removeItem(TEAM_ID_KEY);
}
