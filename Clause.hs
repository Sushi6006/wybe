--  File     : Clause.hs
--  RCS      : $Id$
--  Author   : Peter Schachte
--  Origin   : Sat Jun 28 22:40:58 2014
--  Purpose  : 
--  Copyright: � 2014 Peter Schachte.  All rights reserved.
--

----------------------------------------------------------------
--                 Clause compiler monad
----------------------------------------------------------------

module Clause (compileBody) where

import AST
import Data.Map as Map
import Data.Set as Set
import Data.List as List
import Data.Maybe
import Text.ParserCombinators.Parsec.Pos
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.State
import Control.Monad.Trans (lift,liftIO)


-- |The clause compiler monad is a state transformer monad carrying the 
--  clause compiler state over the compiler monad.
type ClauseComp = StateT ClauseCompState Compiler


-- |The state of compilation of a clause; used by the ClauseComp
-- monad.
data ClauseCompState = ClauseComp {
    varMap :: Map VarName Int,   -- ^current var number for each var
    resourceMap :: Map ResourceName Int
                                    -- ^var number and type for each resource
  }


initClauseComp :: ClauseCompState
initClauseComp = ClauseComp Map.empty Map.empty


nextVar :: String -> ClauseComp PrimVarName
nextVar name = do
    resMap <- gets resourceMap
    case Map.lookup name resMap of
        Nothing -> do
            modify (\s -> s { varMap = Map.alter (Just . maybe 0 (+1)) name $ 
                                       varMap s })
        Just n ->
            modify (\s -> s { resourceMap = Map.insert name (n+1) $
                                            resourceMap s})
    currVar name Nothing


currVar :: String -> OptPos -> ClauseComp PrimVarName
currVar name pos = do
    resMap <- gets resourceMap
    case Map.lookup name resMap of
        Nothing -> do
            dict <- gets varMap
            case Map.lookup name dict of
                Nothing -> do
                       lift $ message Error
                           ("Uninitialised variable '" ++ name ++ "'") pos
                       return $ PrimVarName name (-1)
                Just n -> return $ PrimVarName name n
        Just n -> return $ PrimVarName name n



mkPrimVarName :: Map String Int -> String -> PrimVarName
mkPrimVarName dict name =
    case Map.lookup name dict of
        Nothing -> PrimVarName name 0
        -- must have been introduced in resource expansion, which always uses 0
        -- Nothing -> shouldnt $ "Undefined variable '" ++ name ++ "'"
        Just n  -> PrimVarName name n


-- |Run a clause compiler function from the Compiler monad to compile
--  a generated procedure.
evalClauseComp :: ClauseComp t -> Compiler t
evalClauseComp clcomp =
    evalStateT clcomp initClauseComp


-- compileProc :: Int -> Item -> Compiler ProcDef
-- compileProc tmpCtr (ProcDecl vis (ProcProto name params resources) body pos) 
--   = do
--     (params',body') <- evalClauseComp $ do
--         mapM_ nextVar $ List.map paramName $ 
--           List.filter (flowsIn . paramFlow) params
--         startVars <- gets varMap
--         -- liftIO $ putStrLn $ "Compiling body of " ++ name ++ "..."
--         let resMap = List.foldr (\r m -> 
--                                      Map.insert (resourceName
--                                                  (resourceFlowRes r)) 0 m)
--                      Map.empty resources
--         modify (\s -> s { resourceMap = resMap })
--         compiled <- compileBody body
--         -- liftIO $ putStrLn $ "Compiled"
--         endVars <- gets varMap
--         return (List.map (primParam startVars endVars) params, compiled)
--     let def = ProcDef name (PrimProto name params') resources body' pos
--               tmpCtr 0 vis False Nothing []
--     -- liftIO $ putStrLn $ "Compiled version:\n" ++ showProcDef 0 def
--     return def
-- compileProc _ decl =
--     shouldnt $ "compileProc applied to non-proc " ++ show decl


-- |Compile a proc body to LPVM form.  By the time we get here, the 
--  form of the body is very limited:  it is either a single Cond 
--  statement, or it is a list of ProcCalls and ForeignCalls.  
--  Everything else has already been transformed away.
compileBody :: [Placed Stmt] -> ClauseComp ProcBody
compileBody [placed]
  | case content placed of
      Cond _ _ _ _ -> True
      _ -> False
 = do
      let Cond tstStmts tstVar thn els = content placed
      initial <- gets varMap
      tstStmts' <- mapM compileSimpleStmt tstStmts
      tstVar' <- placedApplyM compileArg tstVar
      thn' <- mapM compileSimpleStmt thn
      afterThen <- gets varMap
      modify (\s -> s { varMap = initial })
      els' <- mapM compileSimpleStmt els
      afterElse <- gets varMap
      let final = Map.intersectionWith max afterThen afterElse
      modify (\s -> s { varMap = final })
      let thn'' = thn' ++ reconcilingAssignments afterThen final
      let els'' = els' ++ reconcilingAssignments afterElse final
      case tstVar' of
        ArgVar var _ FlowIn _ _ ->
            return $ ProcBody tstStmts' $
                   PrimFork var False [ProcBody els'' NoFork,
                                       ProcBody thn'' NoFork]
        ArgInt n _ ->
            return $ ProcBody (if n/=0 then tstStmts'++thn'' else els'') NoFork
        _ -> do
            lift $ message Error 
                   ("Condition is non-bool constant or output '" ++
                    show tstVar' ++ "'") $
                 betterPlace (place placed) tstVar
            return $ ProcBody [] NoFork


compileBody stmts = do
    prims <- mapM compileSimpleStmt stmts
    return $ ProcBody prims NoFork

compileSimpleStmt :: Placed Stmt -> ClauseComp (Placed Prim)
compileSimpleStmt stmt = do
    stmt' <- compileSimpleStmt' (content stmt)
    return $ maybePlace stmt' (place stmt)

compileSimpleStmt' :: Stmt -> ClauseComp Prim
compileSimpleStmt' (ProcCall maybeMod name procID args) = do
    args' <- mapM (placedApply compileArg) args
    return $ PrimCall (ProcSpec maybeMod name $
                       trustFromJust "compileSimpleStmt'" procID)
      args'
compileSimpleStmt' (ForeignCall lang name flags args) = do
    args' <- mapM (placedApply compileArg) args
    return $ PrimForeign lang name flags args'
compileSimpleStmt' (Nop) = do
    return $ PrimNop
compileSimpleStmt' stmt =
    shouldnt $ "Normalisation left complex statement:\n" ++ showStmt 4 stmt


compileArg :: Exp -> OptPos -> ClauseComp PrimArg
compileArg = compileArg' Unspecified

compileArg' :: TypeSpec -> Exp -> OptPos -> ClauseComp PrimArg
compileArg' typ (IntValue int) _ = return $ ArgInt int typ
compileArg' typ (FloatValue float) _ = return $ ArgFloat float typ
compileArg' typ (StringValue string) _ = return $ ArgString string typ
compileArg' typ (CharValue char) _ = return $ ArgChar char typ
compileArg' typ (Var name ParamIn flowType) pos = do
    name' <- currVar name pos
    return $ ArgVar name' typ FlowIn flowType False
compileArg' typ (Var name ParamOut flowType) _ = do
    name' <- nextVar name
    return $ ArgVar name' typ FlowOut flowType False
compileArg' _ (Typed exp typ) pos = compileArg' typ exp pos
compileArg' _ arg _ =
    shouldnt $ "Normalisation left complex argument: " ++ show arg


reconcilingAssignments :: Map VarName Int -> Map VarName Int -> [Placed Prim]
reconcilingAssignments caseVars jointVars =
    let vars =
          List.filter (\v -> caseVars ! v /= jointVars ! v) $ keys jointVars
    in  List.map (reconcileOne caseVars jointVars) vars


reconcileOne :: (Map VarName Int) -> (Map VarName Int) -> VarName -> Placed Prim
reconcileOne caseVars jointVars var =
    Unplaced $
    PrimForeign "wybe" "move" []
    [ArgVar (mkPrimVarName jointVars var) Unspecified FlowOut Ordinary False,
     ArgVar (mkPrimVarName caseVars var) Unspecified FlowIn Ordinary False]
