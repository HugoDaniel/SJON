// Named, closed string-format checkers — TS port of `src/StringFormats.zig`.
//
// Each checker returns boolean. Inputs are JS strings (UTF-16 internally);
// codepoint iteration uses spread/`for…of` which expands surrogate pairs
// correctly. Behaviour stays byte-identical with the Zig port so cross-host
// conformance walkers don't diverge.

import type { StringFormat } from './plugin.ts';

export function check(format: StringFormat, text: string): boolean {
  switch (format) {
    case 'email':
      return checkEmail(text);
    case 'uri':
      return checkUri(text);
    case 'path':
      return checkPath(text);
    case 'uuid':
      return checkUuid(text);
    case 'semver':
      return checkSemver(text);
  }
}

export function fromName(text: string): StringFormat | null {
  switch (text) {
    case 'email':
    case 'uri':
    case 'path':
    case 'uuid':
    case 'semver':
      return text;
    default:
      return null;
  }
}

export function codepointLength(text: string): number {
  let n = 0;
  for (const _ of text) n += 1;
  return n;
}

export function checkEmail(text: string): boolean {
  let atCount = 0;
  let atPos = -1;
  for (let i = 0; i < text.length; i += 1) {
    if (text.charCodeAt(i) === 0x40 /* @ */) {
      atCount += 1;
      atPos = i;
    }
  }
  if (atCount !== 1) return false;
  const local = text.slice(0, atPos);
  const host = text.slice(atPos + 1);
  if (local.length === 0 || host.length === 0) return false;
  if (host.startsWith('.') || host.endsWith('.')) return false;
  return host.includes('.');
}

export function checkUri(text: string): boolean {
  if (text.length < 2) return false;
  if (!/^[A-Za-z]/.test(text[0]!)) return false;
  let i = 1;
  while (i < text.length) {
    const c = text[i]!;
    if (c === ':') break;
    if (!/^[A-Za-z0-9+.\-]$/.test(c)) return false;
    i += 1;
  }
  if (i >= text.length) return false; // no `:` found
  if (i + 1 >= text.length) return false; // empty tail
  return true;
}

export function checkPath(text: string): boolean {
  if (text.length === 0) return false;
  if (/\s/.test(text[0]!)) return false;
  for (let i = 0; i < text.length; i += 1) {
    const c = text.charCodeAt(i);
    if (c === 0 || c === 0x0a) return false;
  }
  return true;
}

export function checkUuid(text: string): boolean {
  if (text.length !== 36) return false;
  for (let i = 0; i < 36; i += 1) {
    const c = text[i]!;
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      if (c !== '-') return false;
    } else {
      if (!/^[0-9a-fA-F]$/.test(c)) return false;
    }
  }
  return true;
}

export function checkSemver(text: string): boolean {
  let rest = text;

  // MAJOR.MINOR.PATCH
  let dot = rest.indexOf('.');
  if (dot < 0) return false;
  if (!isNumericIdent(rest.slice(0, dot))) return false;
  rest = rest.slice(dot + 1);
  dot = rest.indexOf('.');
  if (dot < 0) return false;
  if (!isNumericIdent(rest.slice(0, dot))) return false;
  rest = rest.slice(dot + 1);

  let patchEnd = rest.length;
  for (let i = 0; i < rest.length; i += 1) {
    if (rest[i] === '-' || rest[i] === '+') {
      patchEnd = i;
      break;
    }
  }
  if (!isNumericIdent(rest.slice(0, patchEnd))) return false;
  rest = rest.slice(patchEnd);

  if (rest.startsWith('-')) {
    rest = rest.slice(1);
    const plus = rest.indexOf('+');
    const pre = plus >= 0 ? rest.slice(0, plus) : rest;
    if (!isValidPreRelease(pre)) return false;
    rest = plus >= 0 ? rest.slice(plus) : '';
  }

  if (rest.startsWith('+')) {
    rest = rest.slice(1);
    if (!isValidBuild(rest)) return false;
    rest = '';
  }

  return rest.length === 0;
}

function isNumericIdent(s: string): boolean {
  if (s.length === 0) return false;
  if (s.length > 1 && s[0] === '0') return false;
  for (let i = 0; i < s.length; i += 1) {
    if (!/^[0-9]$/.test(s[i]!)) return false;
  }
  return true;
}

function isAlphanumericIdent(s: string): boolean {
  if (s.length === 0) return false;
  for (let i = 0; i < s.length; i += 1) {
    if (!/^[A-Za-z0-9-]$/.test(s[i]!)) return false;
  }
  return true;
}

function hasNonDigit(s: string): boolean {
  for (let i = 0; i < s.length; i += 1) {
    if (!/^[0-9]$/.test(s[i]!)) return true;
  }
  return false;
}

function isValidPreRelease(s: string): boolean {
  if (s.length === 0) return false;
  for (const seg of s.split('.')) {
    if (seg.length === 0) return false;
    if (!isAlphanumericIdent(seg)) return false;
    if (!hasNonDigit(seg)) {
      if (seg.length > 1 && seg[0] === '0') return false;
    }
  }
  return true;
}

function isValidBuild(s: string): boolean {
  if (s.length === 0) return false;
  for (const seg of s.split('.')) {
    if (seg.length === 0) return false;
    if (!isAlphanumericIdent(seg)) return false;
  }
  return true;
}
