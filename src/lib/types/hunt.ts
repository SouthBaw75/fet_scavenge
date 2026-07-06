export type HuntStatus = "draft" | "active" | "closed";
export type HuntItemType = "multiple_choice" | "qr" | "text";

export interface Employee {
  id: string;
  full_name: string;
  department: string | null;
}

export interface Hunt {
  id: string;
  name: string;
  status: HuntStatus;
  settings: HuntSettings;
  created_at: string;
  /** Admin-declared winner (set in Hunt HQ); null until confirmed. */
  winner_team_id: string | null;
}

export interface HuntSettings {
  randomize_item_order?: boolean;
  show_leaderboard_to_teams?: boolean;
}

export interface HuntItem {
  id: string;
  hunt_id: string;
  order_index: number;
  type: HuntItemType;
  prompt: string;
  choices: string[] | null;
  correct_answer: string | null;
  qr_value: string | null;
  /** Optional flavor/educational message shown to a team after they scan a QR stop. */
  reveal_message: string | null;
  points: number;
}

/** What the public/team client is allowed to see for a hunt item (from `public_hunt_items`). */
export type PublicHuntItem = Omit<HuntItem, "correct_answer" | "qr_value">;

export interface Team {
  id: string;
  hunt_id: string;
  employee_id: string | null;
  team_name: string;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
}

export interface TeamProgress {
  id: string;
  team_id: string;
  hunt_item_id: string;
  answer_given: string | null;
  is_correct: boolean;
  answered_at: string;
}
