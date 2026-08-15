// e.* expr factory: golden serialization, composition typing, and
// compile-time arity/type probes (@ts-expect-error, checked by tsc).

import { test } from 'node:test';
import assert from 'node:assert/strict';

import * as e from '../src/expr.ts';
import * as v from '../src/value-ctor.ts';
import { serializeValue } from '../src/value.ts';
import type { NumLike } from '../src/expr.ts';
import type { SjonExpr } from '../src/infer.ts';

test('arithmetic, incl. the canonical nested example', () => {
  assert.equal(serializeValue(e.add(1, e.mul(2, 3))), '(+ 1 (* 2 3))');
  assert.equal(serializeValue(e.add()), '(+)');
  assert.equal(serializeValue(e.sub(10, 7)), '(- 10 7)');
  assert.equal(serializeValue(e.sub(5)), '(- 5)'); // negation
  assert.equal(serializeValue(e.div(10, 2, 5)), '(/ 10 2 5)');
  assert.equal(serializeValue(e.mod(10, 3)), '(mod 10 3)');
});

test('comparison + logical', () => {
  assert.equal(serializeValue(e.lt(1, 2)), '(< 1 2)');
  assert.equal(serializeValue(e.ge(v.sym('x'), 0)), '(>= x 0)');
  assert.equal(serializeValue(e.eq(v.sym('a'), 1)), '(= a 1)');
  assert.equal(serializeValue(e.and(e.lt(1, 2), e.gt(3, 4))), '(and (< 1 2) (> 3 4))');
  assert.equal(serializeValue(e.not(true)), '(not true)');
});

test('control flow', () => {
  assert.equal(serializeValue(e.iff(e.lt(v.sym('x'), 10), 1, 0)), '(if (< x 10) 1 0)');
  assert.equal(serializeValue(e.iff(v.sym('flag'), 1)), '(if flag 1)'); // 2-arg
  assert.equal(
    serializeValue(e.let_([v.sym('x'), 1], e.add(v.sym('x'), 2))),
    '(let [x 1] (+ x 2))',
  );
  assert.equal(serializeValue(e.cond(e.lt(v.sym('x'), 0), -1, 1)), '(cond (< x 0) -1 1)');
});

test('higher-order binders carry [x] vectors', () => {
  assert.equal(
    serializeValue(e.map([v.sym('x')], v.sym('xs'), e.mul(v.sym('x'), 2))),
    '(map [x] xs (* x 2))',
  );
  assert.equal(
    serializeValue(
      e.fold([v.sym('acc'), v.sym('x')], 0, v.sym('xs'), e.add(v.sym('acc'), v.sym('x'))),
    ),
    '(fold [acc x] 0 xs (+ acc x))',
  );
});

// --- Closure-binder sugar (build-time desugaring to the first-order AST) ----

type ExprNode = { $expr: unknown[] };

test('map arrow sugar desugars to the explicit [binder] AST', () => {
  const out = e.map([1, 2, 3], (x) => e.mul(x, 2));
  const node = out as unknown as ExprNode;
  assert.equal(node.$expr[0], 'map');
  const binder = node.$expr[1] as ReadonlyArray<{ $sym: string }>;
  assert.equal(binder.length, 1);
  const name = binder[0]!.$sym;
  assert.match(name, /^__sjon_b\d+$/); // reserved-prefix gensym that lexes as a symbol
  assert.deepEqual(node.$expr[2], [1, 2, 3]);
  // The arrow ran once with the fresh symbol; the body reuses it verbatim.
  assert.deepEqual(node.$expr[3], { $expr: ['*', { $sym: name }, 2] });
  assert.equal(serializeValue(out), `(map [${name}] [1 2 3] (* ${name} 2))`);
});

test('filter / any / all arrow sugar bind one fresh symbol', () => {
  const f = e.filter([1, 2, 3, 4], (x) => e.gt(x, 2)) as unknown as ExprNode;
  assert.equal(f.$expr[0], 'filter');
  const fName = (f.$expr[1] as Array<{ $sym: string }>)[0]!.$sym;
  assert.deepEqual(f.$expr[3], { $expr: ['>', { $sym: fName }, 2] });

  const a = e.any([1, 2], (x) => e.eq(x, 1)) as unknown as ExprNode;
  assert.equal(a.$expr[0], 'any');
});

test('nested map sugar mints distinct binder symbols', () => {
  const out = e.map([1, 2], (x) => e.map([3, 4], (y) => e.add(x, y)));
  const outer = out as unknown as ExprNode;
  const xName = (outer.$expr[1] as Array<{ $sym: string }>)[0]!.$sym;
  const inner = outer.$expr[3] as ExprNode;
  const yName = (inner.$expr[1] as Array<{ $sym: string }>)[0]!.$sym;
  assert.notEqual(xName, yName);
  assert.deepEqual(inner.$expr[3], { $expr: ['+', { $sym: xName }, { $sym: yName }] });
});

test('fold arrow sugar binds [acc x] and emits the first-order AST', () => {
  const out = e.fold(0, [1, 2, 3], (acc, x) => e.add(acc, x));
  const node = out as unknown as ExprNode;
  assert.equal(node.$expr[0], 'fold');
  const binder = node.$expr[1] as ReadonlyArray<{ $sym: string }>;
  assert.equal(binder.length, 2);
  const accName = binder[0]!.$sym;
  const xName = binder[1]!.$sym;
  assert.notEqual(accName, xName);
  assert.deepEqual(node.$expr[2], 0);
  assert.deepEqual(node.$expr[3], [1, 2, 3]);
  assert.deepEqual(node.$expr[4], { $expr: ['+', { $sym: accName }, { $sym: xName }] });
});

test('the explicit binder form still works alongside the sugar', () => {
  assert.equal(
    serializeValue(e.filter([v.sym('x')], v.sym('xs'), e.gt(v.sym('x'), 0))),
    '(filter [x] xs (> x 0))',
  );
});

test('vectors + math + constants', () => {
  assert.equal(serializeValue(e.vec3(1, 2, 3)), '(vec3 1 2 3)');
  assert.equal(serializeValue(e.pi()), '(pi)');
  assert.equal(serializeValue(e.lerp(0, 10, 0.5)), '(lerp 0 10 0.5)');
  assert.equal(serializeValue(e.clamp(v.sym('t'), 0, 1)), '(clamp t 0 1)');
  assert.equal(serializeValue(e.normalize(v.sym('p'))), '(normalize p)');
  assert.equal(serializeValue(e.radians(90)), '(radians 90)');
  assert.equal(serializeValue(e.smoothstep(0, 1, v.sym('t'))), '(smoothstep 0 1 t)');
});

test('seeded random aliases', () => {
  assert.equal(serializeValue(e.rand01(1, 2)), '(rand01 1 2)');
  assert.equal(serializeValue(e.randRange(1, 2, 0, 10)), '(rand-range 1 2 0 10)');
  assert.equal(serializeValue(e.randInt(1, 2, 0, 6)), '(rand-int 1 2 0 6)');
  assert.equal(serializeValue(e.randBool(1, 2, 0.5)), '(rand-bool 1 2 0.5)');
});

test('call() is the untyped escape hatch for non-core ops', () => {
  assert.equal(serializeValue(e.call('custom-op', 1, v.sym('x'))), '(custom-op 1 x)');
  assert.equal(serializeValue(e.call('noargs')), '(noargs)');
});

// --- Composition typing (compile-time, positive) ---------------------------

function _composition(): void {
  // A NumLike accepts a literal, a numeric expr, or a symbol reference.
  const a: NumLike = 1;
  const b: NumLike = e.mul(2, 3);
  const c: NumLike = v.sym('x');
  const sum: SjonExpr<number> = e.add(a, b, c);
  void sum;
  // Nested exprs flow as args because they are NumLike.
  const nested: SjonExpr<number> = e.add(1, e.mul(2, e.sub(10, 7)));
  void nested;
  // Branch result types propagate through iff.
  const branched: SjonExpr<number> = e.iff(e.lt(1, 2), e.add(1, 2), 0);
  void branched;
}
void _composition;

// --- Arity / arg-type probes (compile-time negatives) ----------------------

function _negativeProbes(): void {
  // @ts-expect-error mod needs exactly 2 args
  e.mod(1);
  // @ts-expect-error vec3 needs exactly 3 args
  e.vec3(1, 2);
  // @ts-expect-error pi takes no args
  e.pi(1);
  // @ts-expect-error binary comparison takes exactly 2 args
  e.lt(1, 2, 3);
  // @ts-expect-error not takes exactly 1 arg
  e.not();
  // @ts-expect-error div needs at least 2 args
  e.div(1);
  // @ts-expect-error a string literal is not a NumLike
  e.add('hello');
  // @ts-expect-error a boolean literal is not a NumLike
  e.mul(true, 1);
}
void _negativeProbes;
