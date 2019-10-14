--
-- Copyright 2016, NICTA
--
-- This software may be distributed and modified according to the terms of
-- the GNU General Public License version 2. Note that NO WARRANTY is provided.
-- See "LICENSE_GPLv2.txt" for details.
--
-- @TAG(NICTA_GPL)
--

{-# LANGUAGE LambdaCase #-}

module Cogent.TypeCheck.Subst where

import Cogent.Common.Types
import Cogent.Compiler (__impossible)
import Cogent.Surface
import qualified Cogent.TypeCheck.ARow as ARow
import Cogent.TypeCheck.Assignment
import Cogent.TypeCheck.Base
import qualified Cogent.TypeCheck.Row as Row
import Cogent.Util

import qualified Data.IntMap as M
import qualified Data.Map as DM
import Data.Bifunctor (second)
import Data.Maybe
import Data.Monoid hiding (Alt)
import Prelude hiding (lookup)

data AssignResult = Type TCType
                  | Sigil (Sigil (Maybe DataLayoutExpr))
                  | Row (Either (Row.Row TCType) Row.Shape)
                  | Taken Taken
#ifdef BUILTIN_ARRAYS
                  | ARow (ARow.ARow SExpr)
                  | Expr SExpr
#endif

newtype Subst = Subst (M.IntMap AssignResult)
              deriving Show

ofType :: Int -> TCType -> Subst
ofType i t = Subst (M.fromList [(i, Type t)])

ofRow :: Int -> Row.Row TCType -> Subst 
ofRow i t = Subst (M.fromList [(i, Row $ Left t)])

ofARow :: Int -> ARow.ARow SExpr -> Subst
ofARow i t = Subst (M.fromList [(i, ARow t)])

ofSigil :: Int -> Sigil (Maybe DataLayoutExpr) -> Subst
ofSigil i t = Subst (M.fromList [(i, Sigil t)])

ofShape :: Int -> Row.Shape -> Subst
ofShape i t = Subst (M.fromList [(i, Row $ Right t)])

ofExpr :: Int -> SExpr -> Subst
ofExpr i e = Subst (M.fromList [(i, Expr e)])

substToAssign :: Subst -> Assignment
substToAssign (Subst m) = Assignment . M.map unExpr $ M.filter isAssign m
  where isAssign (Expr _) = True; isAssign _ = False
        unExpr   (Expr x) = x   ; unExpr   _ = __impossible "unExpr"

null :: Subst -> Bool
null (Subst x) = M.null x

#if __GLASGOW_HASKELL__ < 803
instance Monoid Subst where
  mempty = Subst M.empty
  mappend (Subst a) (Subst b) = Subst (a <> b)
#else
instance Semigroup Subst where
  Subst a <> Subst b = Subst (a <> b)
instance Monoid Subst where
  mempty = Subst M.empty
#endif

apply :: Subst -> TCType -> TCType
apply (Subst f) (U x)
  | Just (Type t) <- M.lookup x f
  = apply (Subst f) t
  | otherwise
  = U x
apply sub@(Subst f) (V r)
  | Just rv <- Row.var r
  , Just (Row e) <- M.lookup rv f =
    -- Expand an incomplete row with some more entries (and a fresh row
    -- variable), or close an incomplete row by assigning an ordering (a
    -- shape) to its fields.
    case e of
      Left r' -> apply sub (V (Row.expand r r'))
      Right sh -> apply sub (V (Row.close r sh))
apply sub@(Subst f) (R r s)
  | Just rv <- Row.var r
  , Just (Row e) <- M.lookup rv f =
    case e of
      Left r' -> apply sub (R (Row.expand r r') s)
      Right sh -> apply sub (R (Row.close r sh) s)
apply (Subst f) t@(R r (Right x))
  | Just (Sigil s) <- M.lookup x f = apply (Subst f) (R r (Left s))
apply f (V x) = V (fmap (apply f) x)
apply f (R x s) = R (fmap (apply f) x) s
#ifdef BUILTIN_ARRAYS
apply (Subst f) (A t l (Right x) tkns)
  | Just (Sigil s) <- M.lookup x f = apply (Subst f) (A t l (Left s) tkns)
<<<<<<< HEAD
=======
apply (Subst f) (A t l s (ARow.ARow es us ma (Just x)))
  | Just (ARow r'@(ARow.ARow es' _ _ mv')) <- M.lookup x f
  -- It's guaranteed that 'r\'' is reduced.
  = apply (Subst f) (A t l s $ ARow.ARow (M.union es es') us ma mv')
#endif
apply f (V x) = V (fmap (apply f) x)
apply f (R x s) = R (fmap (apply f) x) s
#ifdef BUILTIN_ARRAYS
>>>>>>> compiler: manage to tc simple array put ops
apply f (A x l s tkns) = A (apply f x) (assign (substToAssign f) l) s (fmap (assign $ substToAssign f) tkns)
#endif
apply f (T x) = T (fmap (apply f) x)
apply f (Synonym n ts) = Synonym n (fmap (apply f) ts)

applyAlts :: Subst -> [Alt TCPatn TCExpr] -> [Alt TCPatn TCExpr]
applyAlts = map . applyAlt

applyAlt :: Subst -> Alt TCPatn TCExpr -> Alt TCPatn TCExpr
applyAlt s = fmap (applyE s) . ffmap (fmap (apply s))

applyCtx :: Subst -> ErrorContext -> ErrorContext
applyCtx s (SolvingConstraint c) = SolvingConstraint (applyC s c)
applyCtx s (InExpression e t) = InExpression e (apply s t)
applyCtx s c = c

applyErr :: Subst -> TypeError -> TypeError
applyErr s (TypeMismatch t1 t2)     = TypeMismatch (apply s t1) (apply s t2)
applyErr s (RequiredTakenField f t) = RequiredTakenField f (apply s t)
applyErr s (TypeNotShareable t m)   = TypeNotShareable (apply s t) m
applyErr s (TypeNotEscapable t m)   = TypeNotEscapable (apply s t) m
applyErr s (TypeNotDiscardable t m) = TypeNotDiscardable (apply s t) m
applyErr s (PatternsNotExhaustive t ts) = PatternsNotExhaustive (apply s t) ts
applyErr s (UnsolvedConstraint c os) = UnsolvedConstraint (applyC s c) os
applyErr s (NotAFunctionType t) = NotAFunctionType (apply s t)
applyErr s e = e

applyWarn :: Subst -> TypeWarning -> TypeWarning
applyWarn s (UnusedLocalBind v) = UnusedLocalBind v
applyWarn _ w = w

applyC :: Subst -> Constraint -> Constraint
applyC s (a :< b) = apply s a :< apply s b
applyC s (a :=: b) = apply s a :=: apply s b
applyC s (a :& b) = applyC s a :& applyC s b
applyC s (a :@ c) = applyC s a :@ applyCtx s c
applyC s (Upcastable a b) = apply s a `Upcastable` apply s b
applyC s (Share t m) = Share (apply s t) m
applyC s (Drop t m) = Drop (apply s t) m
applyC s (Escape t m) = Escape (apply s t) m
#ifdef BUILTIN_ARRAYS
applyC s (Arith e) = Arith $ assign (substToAssign s) e
#endif
applyC s (Unsat e) = Unsat (applyErr s e)
applyC s (SemiSat w) = SemiSat (applyWarn s w)
applyC s Sat = Sat
applyC s (Exhaustive t ps) = Exhaustive (apply s t) ps
applyC s (Solved t) = Solved (apply s t)
applyC s (IsPrimType t) = IsPrimType (apply s t)

applyE :: Subst -> TCExpr -> TCExpr
applyE s (TE t e l) = TE (apply s t)
                         ( fmap (fmap (apply s))
                         $ ffmap (fmap (apply s))
                         $ fffmap (fmap (apply s))
                         $ ffffmap (apply s) e)
                         l
