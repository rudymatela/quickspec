{-# LANGUAGE GADTs #-}
module QuickSpec.Pruning.E where

import QuickSpec.Base
import QuickSpec.Term
import QuickSpec.Type
import QuickSpec.Utils
import QuickSpec.Pruning
import System.IO
import System.IO.Unsafe
import Control.Monad.Trans.State.Strict
import Data.Map(Map)
import qualified Data.Map as Map
import qualified Data.ByteString.Char8 as BS
import qualified Jukebox.Form as Jukebox
import qualified Jukebox.Name as Jukebox
import qualified Jukebox.Provers.E as Jukebox
import qualified Jukebox.Toolbox as Jukebox
import qualified Jukebox.Monotonox.ToFOF as Jukebox
import qualified Jukebox.Clausify as Jukebox

newtype EPruner = S [(PruningTerm, PruningTerm)]

instance Pruner EPruner where
  emptyPruner = S []
  unifyUntyped = eUnify
  repUntyped _ = return Nothing

eliftIO :: IO a -> State EPruner a
eliftIO x = unsafePerformIO (fmap return x)

eUnify :: PruningTerm -> PruningTerm -> State EPruner Bool
eUnify t u = do
  S eqs <- get
  -- eliftIO (putStr ("\nSending to E: " ++ prettyShow (decodeTypes t) ++ " = " ++ prettyShow (decodeTypes u) ++ ": ") >> hFlush stdout)
  let opts = Jukebox.EFlags "eprover" (Just 30) Nothing
      prob = translate eqs t u
  prob' <- eliftIO (Jukebox.toFofIO (Jukebox.clausifyIO (Jukebox.ClausifyFlags False)) (Jukebox.tags False) prob)
  res <- eliftIO (Jukebox.runE opts prob')
  --eliftIO (print res)
  case res of
    Left Jukebox.Unsatisfiable ->
      -- Pruned
      return True
    _ -> do
      -- Not pruned
      modify (\(S eqs) -> S ((t,u):eqs))
      return False

translate :: [(PruningTerm, PruningTerm)] -> PruningTerm -> PruningTerm ->
             Jukebox.Closed [Jukebox.Input Jukebox.Form]
translate eqs t u = Jukebox.close_ Jukebox.stdNames $ do
  ty <- Jukebox.newType "i"
  let terms = [t, u] ++ concat [ [l, r] | (l, r) <- eqs ]
      vs = usort (concatMap vars terms)
      fs = usort (concatMap funs terms)
  varSyms <- sequence [ Jukebox.newSymbol (makeVarName x) ty | x <- vs ]
  funSyms <- sequence [ Jukebox.newFunction (makeFunName x) [] ty | x <- fs]
  let var = find (Map.fromList (zip vs varSyms))
      fun = find (Map.fromList (zip fs funSyms))
      input kind form = Jukebox.Input (BS.pack "clause") kind form
  return (input Jukebox.Conjecture (conjecturise (translateEq var fun (t, u))):
          map (input Jukebox.Axiom . translateEq var fun) eqs)

makeVarName :: PruningVariable -> String
makeVarName (TermVariable x) = 'X':show (varNumber x)
makeVarName (TypeVariable x) = 'A':show (tyVarNumber x)

makeFunName :: PruningConstant -> String
makeFunName (TermConstant x) = 'f':conName x
makeFunName (TypeConstant x) = 't':show x
makeFunName HasType          = "as"

conjecturise :: Jukebox.Symbolic a => a -> a
conjecturise t =
  case Jukebox.typeOf t of
    Jukebox.Term -> term t
    _ -> Jukebox.recursively conjecturise t
  where
    term (Jukebox.Var (x Jukebox.::: t)) = (x Jukebox.::: Jukebox.FunType [] t) Jukebox.:@: []
    term t = Jukebox.recursively conjecturise t

find :: Ord k => Map k v -> k -> v
find m x = Map.findWithDefault (error "E: not found") x m

translateEq :: (PruningVariable -> Jukebox.Variable) ->
               (PruningConstant -> Jukebox.Function) ->
               (PruningTerm, PruningTerm) -> Jukebox.Form
translateEq var fun (t, u) =
  Jukebox.Literal (Jukebox.Pos (translateTerm var fun t Jukebox.:=: translateTerm var fun u))

translateTerm :: (PruningVariable -> Jukebox.Variable) ->
                 (PruningConstant -> Jukebox.Function) ->
                 PruningTerm -> Jukebox.Term
translateTerm var _fun (Var x) = Jukebox.Var (var x)
translateTerm var  fun (Fun f ts) = fun f Jukebox.:@: map (translateTerm var fun) ts

