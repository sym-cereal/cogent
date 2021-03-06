-- |
-- Module      : Minigent.TC.Solver
-- Copyright   : (c) Data61 2018-2019
--                   Commonwealth Science and Research Organisation (CSIRO)
--                   ABN 41 687 119 230
-- License     : BSD3
--
-- The solver portion of the type inference.
--
-- May be used qualified or unqualified.
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Minigent.TC.Solver
  ( Solver
  , runSolver
  , solve
  , substAssign
  ) where

import Minigent.TC.Normalise
import Minigent.TC.Simplify
import Minigent.TC.Unify
import Minigent.TC.Equate
import Minigent.TC.SinkFloat
import Minigent.TC.Assign
import Minigent.Fresh
import Minigent.Syntax
import Minigent.Syntax.Utils
import Minigent.Syntax.PrettyPrint

import qualified Minigent.Syntax.Utils.Rewrite as Rewrite

import Control.Applicative
import Control.Monad.Trans.Maybe
import Control.Monad.State
import Control.Monad.Writer
import Data.Maybe (fromMaybe)

import Debug.Trace

-- | A monad that combines writer effects for accumulating assignments to
--   unification variables, and fresh variables.
newtype Solver a = Solver (WriterT [Assign] (FreshT VarName IO) a)
        deriving ( Monad, Applicative, Functor
                 , MonadFresh VarName, MonadWriter [Assign]
                 )

-- | Given a set of axioms and a set of constraints to solve, attempt to
--   find assignments to satisfy all the constraints assuming the axioms.
--
--   Right now, only 'Share', 'Drop' and 'Escape' constraints on type
--   variables can be axioms.
--
--   Returns any constraints that could not be satisfied. So, an empty list
--   means that the solver successfully solved everything.
solve :: [Constraint] -> [Constraint] -> Solver [Constraint]
solve axs cs = do
  cs'' <- runMaybeT (Rewrite.run' solverRewrites cs)
  case cs'' of
    Nothing -> pure (normaliseConstraints cs)
    Just a  -> pure a
  where
    solverRewrites :: Rewrite.Rewrite' Solver [Constraint]
    solverRewrites = Rewrite.untilFixedPoint $
      -- Rewrite.debugNewline "SOLV" debugPrettyConstraints <>
      Rewrite.pre normaliseConstraints (
          -- debugStr "[simp]" <>
          Rewrite.lift (simplify axs) <>
          -- debugStr "[unify]" <>
          unify <>
          -- debugStr "[equate]" <>
          Rewrite.lift equate <>
          -- debugStr "[sink/float]" <>
          sinkFloat)

-- | Run a solver computation.
runSolver :: Solver a -> FreshT VarName IO (a,[Assign])
runSolver (Solver x) = runWriterT x

debugStr :: String -> Rewrite.Rewrite' Solver a
debugStr s = Rewrite.Rewrite $ \cs -> do
  _ <- (lift . Solver . lift . lift . traceIO $ s :: MaybeT Solver ())
  empty
