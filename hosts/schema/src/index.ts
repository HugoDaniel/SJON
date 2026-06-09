// @sjon/schema — fluent, host-independent schema authoring + Zod-style
// inference for SJON.
//
//   import { s } from '@sjon/schema';
//
//   const Profile = s.form('profile', {
//     handle: s.slug(),
//     email: s.email().optional(),
//     score: s.number().min(0).max(100).optional(),
//   }, 'bounds');
//
//   type Profile = s.infer<typeof Profile>;
//   // { $form: "profile"; $ns: "bounds"; handle: string; email?: string; score?: number }
//
//   s.use(backend);                       // a WASM or native ValidateBackend
//   const data = Profile.parse(sjonText); // typed, or throws SjonValidationError
//
// The builder is pure TS with zero runtime deps. Validation/projection is
// delegated to an injected `ValidateBackend` (see `hosts/web` and
// `hosts/typescript-parity` for adapters). The serialized `(plugin …)`
// manifest (`Form.manifest()`) is the universal cross-language contract.

// The `s` namespace: a module namespace (not a const object) so both the
// value factory (`s.form`, `s.string`, …) and the type helpers
// (`s.infer<T>`, `s.input<T>`) resolve off the same name.
export * as s from './builder.ts';

// Flat re-exports for users who prefer `import { form, string } from …`.
export * from './builder.ts';

// The write side (plan 02): `v.*` atom values, `e.*` exprs, the `sjon\`\``
// template, and the `serializeValue` keystone. `v`/`e` are module namespaces
// (like `s`) so `v.sym(...)` / `e.add(...)` read naturally.
export * as v from './value-ctor.ts';
export * as e from './expr.ts';
export { sjon } from './template.ts';
export { quoteSjonString, serializeValue } from './value.ts';
export type { SjonFormValue, SjonValue } from './value.ts';
export type { Binder, BoolLike, ExprLike, NumLike, Ref, VecLike } from './expr.ts';

// The edit / write-back side (plan 03): the `edit.*` action builders + the pure
// differ as a namespace, plus `sjonValueEqual`/`diffToActions` flat. The typed
// edit *methods* live on `FormNode`/`FormDocument` (see `s.form(...).setKey` etc.).
export * as edit from './edit.ts';
export { diffToActions, sjonValueEqual } from './edit.ts';
export type { EditAction, EditPath } from './edit.ts';

// Inference-layer types: node interfaces, brand aliases, helpers.
export type {
  AnyFormNode,
  AnyNode,
  CrossRef,
  FixedTuple,
  FormDocument,
  FormFieldNode,
  FormIn,
  FormInput,
  FormNode,
  FormOut,
  Keyword,
  Node,
  NumberNode,
  OptionalNode,
  PluginNode,
  RemoveKeyPath,
  ReplacePath,
  ReplaceValue,
  SetKeyPath,
  SetKeyValue,
  ShapeRecord,
  SjonDate,
  SjonExpr,
  SjonTime,
  SjonUnit,
  StringNode,
  Symbol_,
  VectorNode,
  infer,
  input,
} from './infer.ts';

// Backend seam: implement `ValidateBackend` in a host adapter.
export {
  SjonEditError,
  SjonValidationError,
  currentBackend,
  requireBackend,
  requireEditBackend,
  useBackend,
} from './backend.ts';
export type {
  BackendDiagnostic,
  EditBackend,
  ParseOptions,
  SafeEditResult,
  SafeParseResult,
  ToDtsOptions,
  ValidateBackend,
  ValidateOutcome,
} from './backend.ts';

// Builder IR + serializer, for advanced/ahead-of-time manifest generation.
export { serializeFormAsPlugin, serializePlugin } from './serialize.ts';
export type {
  CrossRefIR,
  FormDef,
  NamedKindDef,
  NodeDef,
  NumericBoundsIR,
  PluginDef,
  ShapeIR,
  StringBoundsIR,
} from './shape.ts';
