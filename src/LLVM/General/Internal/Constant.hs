{-# LANGUAGE
  TemplateHaskell,
  QuasiQuotes,
  TupleSections,
  MultiParamTypeClasses,
  FlexibleInstances,
  FlexibleContexts,
  ScopedTypeVariables
  #-}
module LLVM.General.Internal.Constant where

import qualified Language.Haskell.TH as TH
import qualified Language.Haskell.TH.Quote as TH
import qualified LLVM.General.Internal.InstructionDefs as ID

import Control.Applicative
import Data.Word (Word32, Word64)
import Data.Bits
import Control.Monad.State
import Control.Monad.AnyCont

import qualified Data.Map as Map
import Foreign.Ptr
import Foreign.Storable (Storable, sizeOf)

import qualified LLVM.General.Internal.FFI.Constant as FFI
import qualified LLVM.General.Internal.FFI.GlobalValue as FFI
import qualified LLVM.General.Internal.FFI.Instruction as FFI
import qualified LLVM.General.Internal.FFI.LLVMCTypes as FFI
import qualified LLVM.General.Internal.FFI.PtrHierarchy as FFI
import qualified LLVM.General.Internal.FFI.User as FFI
import qualified LLVM.General.Internal.FFI.Value as FFI

import qualified LLVM.General.AST.Constant as A (Constant)
import qualified LLVM.General.AST.Constant as A.C hiding (Constant)
import qualified LLVM.General.AST.Type as A
import qualified LLVM.General.AST.IntegerPredicate as A (IntegerPredicate)
import qualified LLVM.General.AST.FloatingPointPredicate as A (FloatingPointPredicate)
import qualified LLVM.General.AST.Float as A.F

import LLVM.General.Internal.Coding
import LLVM.General.Internal.DecodeAST
import LLVM.General.Internal.EncodeAST
import LLVM.General.Internal.Context
import LLVM.General.Internal.Type ()
import LLVM.General.Internal.IntegerPredicate ()
import LLVM.General.Internal.FloatingPointPredicate ()

allocaWords :: forall a m . (Storable a, MonadAnyCont IO m, Monad m, MonadIO m) => Word32 -> m (Ptr a)
allocaWords nBits = do
  allocaArray (((nBits-1) `div` (8*(fromIntegral (sizeOf (undefined :: a))))) + 1)

instance EncodeM EncodeAST A.Constant (Ptr FFI.Constant) where
  encodeM c = scopeAnyCont $ case c of
    A.C.Int { A.C.constantType = t@(A.IntegerType bits), A.C.integerValue = v } -> do
      t' <- encodeM t
      words <- encodeM [
        fromIntegral ((v `shiftR` (w*64)) .&. 0xffffffffffffffff) :: Word64
        | w <- [0 .. ((fromIntegral bits-1) `div` 64)] 
       ]
      liftIO $ FFI.constantIntOfArbitraryPrecision t' words
    A.C.Float { A.C.constantType = t@(A.FloatingPointType nBits), A.C.floatValue = v } -> do
      Context context <- gets encodeStateContext
      words <- allocaWords nBits
      case (nBits, v) of
        (16, A.F.Half f) -> poke (castPtr words) f
        (32, A.F.Single f) -> poke (castPtr words) f
        (64, A.F.Double f) -> poke (castPtr words) f
        (80, A.F.X86_FP80 high low) -> do
          pokeByteOff (castPtr words) 0 low
          pokeByteOff (castPtr words) 8 high
        (128, A.F.Quadruple high low) -> do
          pokeByteOff (castPtr words) 0 low
          pokeByteOff (castPtr words) 8 high
        x -> fail $ "invalid type encoding float: " ++ show x
      nBits <- encodeM nBits
      liftIO $ FFI.constantFloatOfArbitraryPrecision context nBits words
    A.C.GlobalReference n -> FFI.upCast <$> referGlobal n
    A.C.BlockAddress f b -> do
      f' <- referGlobal f
      b' <- getBlockForAddress f b
      liftIO $ FFI.blockAddress (FFI.upCast f') b'
    A.C.Struct p ms -> do
      Context context <- gets encodeStateContext
      p <- encodeM p
      ms <- encodeM ms
      liftIO $ FFI.constStructInContext context ms p
    o -> $(do
      let constExprInfo =  ID.outerJoin ID.astConstantRecs (ID.innerJoin ID.astInstructionRecs ID.instructionDefs)
      TH.caseE [| o |] $ do
        (name, (Just (TH.RecC n fs'), instrInfo)) <- Map.toList constExprInfo
        let fns = [ TH.mkName . TH.nameBase $ fn | (fn, _, _) <- fs' ]
            coreCall n = TH.dyn $ "FFI.constant" ++ n
            buildBody c = [ TH.bindS (TH.varP fn) [| encodeM $(TH.varE fn) |] | fn <- fns ]
                          ++ [ TH.noBindS [| liftIO $(foldl TH.appE c (map TH.varE fns)) |] ]
        core <- case instrInfo of
          Just (_, iDef) -> do
            let opcode = TH.dataToExpQ (const Nothing) (ID.cppOpcode iDef)
            case ID.instructionKind iDef of
              ID.Binary -> return [| $(coreCall "BinaryOperator") $(opcode) |]
              ID.Cast -> return [| $(coreCall "Cast") $(opcode) |]
              _ -> return $ coreCall name
          Nothing -> if (name `elem` ["Vector", "Null", "Array"]) 
                      then return $ coreCall name
                      else []
        return $ TH.match
          (TH.recP n [(fn,) <$> (TH.varP . TH.mkName . TH.nameBase $ fn) | (fn, _, _) <- fs'])
          (TH.normalB (TH.doE (buildBody core)))
          []
      )

instance DecodeM DecodeAST A.Constant (Ptr FFI.Constant) where
  decodeM c = scopeAnyCont $ do
    let v = FFI.upCast c :: Ptr FFI.Value
        u = FFI.upCast c :: Ptr FFI.User
    t <- decodeM =<< liftIO (FFI.typeOf v)
    valueSubclassId <- liftIO $ FFI.getValueSubclassId v
    nOps <- liftIO $ FFI.getNumOperands u
    let globalRef = return A.C.GlobalReference `ap` (getGlobalName =<< liftIO (FFI.isAGlobalValue v))
        op = decodeM <=< liftIO . FFI.getConstantOperand c
        getConstantOperands = mapM op [0..nOps-1] 
        getConstantData = do
          let nElements = case t of
                            A.VectorType n _ -> n
                            A.ArrayType n _ | n <= (fromIntegral (maxBound :: Word32)) -> fromIntegral n
          forM [0..nElements-1] $ do
             decodeM <=< liftIO . FFI.getConstantDataSequentialElementAsConstant c . fromIntegral

    case valueSubclassId of
      [FFI.valueSubclassIdP|Function|] -> globalRef
      [FFI.valueSubclassIdP|GlobalAlias|] -> globalRef
      [FFI.valueSubclassIdP|GlobalVariable|] -> globalRef
      [FFI.valueSubclassIdP|ConstantInt|] -> do
        np <- alloca
        wsp <- liftIO $ FFI.getConstantIntWords c np
        n <- peek np
        words <- decodeM (n, wsp)
        return $ A.C.Int t (foldr (\b a -> (a `shiftL` 64) .|. fromIntegral (b :: Word64)) 0 words)
      [FFI.valueSubclassIdP|ConstantFP|] -> do
        let A.FloatingPointType nBits = t
        ws <- allocaWords nBits
        liftIO $ FFI.getConstantFloatWords c ws
        A.C.Float t <$> (
          case nBits of
            16 -> A.F.Half <$> peek (castPtr ws)
            32 -> A.F.Single <$> peek (castPtr ws)
            64 -> A.F.Double <$> peek (castPtr ws)
            80 -> A.F.X86_FP80 <$> peekByteOff (castPtr ws) 8 <*> peekByteOff (castPtr ws) 0
            128 -> A.F.Quadruple <$> peekByteOff (castPtr ws) 8 <*> peekByteOff (castPtr ws) 0
          )
      [FFI.valueSubclassIdP|ConstantPointerNull|] -> return $ A.C.Null t
      [FFI.valueSubclassIdP|ConstantAggregateZero|] -> return $ A.C.Null t
      [FFI.valueSubclassIdP|UndefValue|] -> return $ A.C.Undef t
      [FFI.valueSubclassIdP|BlockAddress|] -> 
            return A.C.BlockAddress 
               `ap` (getGlobalName =<< do liftIO $ FFI.isAGlobalValue =<< FFI.getBlockAddressFunction c)
               `ap` (getLocalName =<< do liftIO $ FFI.getBlockAddressBlock c)
      [FFI.valueSubclassIdP|ConstantStruct|] -> 
            return A.C.Struct `ap` (return $ A.isPacked t) `ap` getConstantOperands
      [FFI.valueSubclassIdP|ConstantDataArray|] -> 
            return A.C.Array `ap` (return $ A.elementType t) `ap` getConstantData
      [FFI.valueSubclassIdP|ConstantArray|] -> 
            return A.C.Array `ap` (return $ A.elementType t) `ap` getConstantOperands
      [FFI.valueSubclassIdP|ConstantDataVector|] -> 
            return A.C.Vector `ap` getConstantData
      [FFI.valueSubclassIdP|ConstantExpr|] -> do
            cppOpcode <- liftIO $ FFI.getConstantCPPOpcode c
            $(
              TH.caseE [| cppOpcode |] $ do
                (name, ((TH.RecC n fs, _), iDef)) <- Map.toList $
                      ID.innerJoin (ID.innerJoin ID.astConstantRecs ID.astInstructionRecs) ID.instructionDefs
                let apWrapper o (fn, _, ct) = do
                      a <- case ct of
                             TH.ConT h
                               | h == ''A.Constant -> do
                                               operandNumber <- get
                                               modify (+1)
                                               return [| op $(TH.litE . TH.integerL $ operandNumber) |]
                               | h == ''A.Type -> return [| pure t |]
                               | h == ''A.IntegerPredicate -> 
                                 return [| liftIO $ decodeM =<< FFI.getConstantICmpPredicate c |]
                               | h == ''A.FloatingPointPredicate -> 
                                 return [| liftIO $ decodeM =<< FFI.getConstantFCmpPredicate c |]
                               | h == ''Bool -> case TH.nameBase fn of
                                                  "inBounds" -> return [| liftIO $ decodeM =<< FFI.getInBounds v |]
                             TH.AppT TH.ListT (TH.ConT h) 
                               | h == ''Word32 -> 
                                  return [|
                                        do
                                          np <- alloca
                                          isp <- liftIO $ FFI.getConstantIndices c np
                                          n <- peek np
                                          decodeM (n, isp)
                                        |]
                               | h == ''A.Constant -> 
                                  case TH.nameBase fn of
                                    "indices" -> do
                                      operandNumber <- get
                                      return [| mapM op [$(TH.litE . TH.integerL $ operandNumber)..nOps-1] |]
                             _ -> error $ "unhandled constant expr field type: " ++ show fn ++ " - " ++ show ct
                      return [| $(o) `ap` $(a) |]
                return $ TH.match 
                          (TH.dataToPatQ (const Nothing) (ID.cppOpcode iDef))
                          (TH.normalB (evalState (foldM apWrapper [| return $(TH.conE n) |] fs) 0))
                          []
             )
      _ -> error $ "unhandled constant valueSubclassId: " ++ show valueSubclassId


  
  
