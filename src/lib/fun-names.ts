/** Random fun team-name generator for the registration page. */

const ADJECTIVES = [
  "Turbo",
  "Mighty",
  "Rocket",
  "Blazing",
  "Super",
  "Cosmic",
  "Thunder",
  "Rowdy",
  "Swampy",
  "Cajun",
  "Lightning",
  "Fearless",
  "Golden",
  "Wild",
  "Sneaky",
  "Dancing",
];

const NOUNS = [
  "Gators",
  "Crawfish",
  "Pelicans",
  "Wrenches",
  "Drill Bits",
  "Torque Masters",
  "Gear Heads",
  "Roughnecks",
  "Mud Bugs",
  "Pipeliners",
  "Sparks",
  "Dynamos",
  "Pistons",
  "Turbines",
  "Hurricanes",
  "Fireflies",
];

export function randomTeamName(): string {
  const adj = ADJECTIVES[Math.floor(Math.random() * ADJECTIVES.length)];
  const noun = NOUNS[Math.floor(Math.random() * NOUNS.length)];
  return `The ${adj} ${noun}`;
}
