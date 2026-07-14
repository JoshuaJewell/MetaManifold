// © 2026 Joshua Benjamin Jewell. All rights reserved.
// Licensed under the GNU Affero General Public License version 3 (AGPLv3).

/**
 * Turn the contents of a multi-line textarea into a list of values: one per
 * line, trimmed, with blank lines dropped. The shape every "paste a list
 * freely" field in the app expects.
 */
export function splitLines(text: string): string[] {
  return text.split('\n').map(v => v.trim()).filter(v => v.length > 0)
}
