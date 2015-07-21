{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections  #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE GADTs  #-}
{-# LANGUAGE RankNTypes  #-}
{-# LANGUAGE DeriveDataTypeable  #-}
module Refact.Utils ( -- * Synonyms
                      Module
                    , Stmt
                    , Expr
                    , Decl
                    , Name
                    , Pat
                    , Type
                    -- * Monad
                    , M
                    -- * Utility

                    , mergeAnns
                    , modifyAnnKey
                    , replaceAnnKey
                    , toGhcSrcSpan
                    , findParent

                    ) where

import Language.Haskell.GHC.ExactPrint
import Language.Haskell.GHC.ExactPrint.Types
import Language.Haskell.GHC.ExactPrint.Internal.Types
import Language.Haskell.GHC.ExactPrint.Utils
import Language.Haskell.GHC.ExactPrint.Transform (mergeAnns)

import Data.Data
import HsExpr as GHC hiding (Stmt)
import SrcLoc
import qualified SrcLoc as GHC
import qualified RdrName as GHC
import qualified ApiAnnotation as GHC
import qualified FastString    as GHC
import qualified GHC           as GHC hiding (parseModule)
import Control.Monad.State

import qualified Data.Map as Map
import Data.Maybe


import qualified Refact.Types as R
import Refact.Types hiding (SrcSpan)

import Data.Generics.Schemes
import Unsafe.Coerce
import Data.Typeable

import Debug.Trace

-- Types
--
type M a = State Anns a

type Module = (GHC.Located (GHC.HsModule GHC.RdrName))

type Expr = GHC.Located (GHC.HsExpr GHC.RdrName)

type Type = GHC.Located (GHC.HsType GHC.RdrName)

type Decl = GHC.Located (GHC.HsDecl GHC.RdrName)

type Pat = GHC.LPat GHC.RdrName

type Name = GHC.Located GHC.RdrName

type Stmt = ExprLStmt GHC.RdrName


-- | Replaces an old expression with a new expression
replace :: AnnKey -> AnnKey -> AnnKey -> AnnKey -> Anns -> Maybe Anns
replace old new inp parent as = do
  let anns = getKeywordDeltas as
  oldan <- Map.lookup old anns
  newan <- Map.lookup new anns
  oldDelta <- annEntryDelta  <$> Map.lookup parent anns
  return $ modifyKeywordDeltas (Map.insert inp (combine oldDelta oldan newan)) as

combine :: DeltaPos -> Annotation -> Annotation -> Annotation
combine oldDelta oldann newann =
  Ann { annEntryDelta = newEntryDelta
      , annPriorComments = annPriorComments oldann ++ annPriorComments newann
      , annFollowingComments = annFollowingComments oldann ++ annFollowingComments newann
      , annsDP = (annsDP newann ++ extraComma (annsDP oldann))
      , annSortKey = (annSortKey newann)
      , annCapturedSpan = (annCapturedSpan newann)}
  where
    extraComma [] = []
    extraComma (last -> x) = case fst x of
                              G GHC.AnnComma -> [x]
                              AnnSemiSep -> [x]
                              G GHC.AnnSemi -> [x]
                              _ -> []
    newEntryDelta | deltaRow oldDelta > 0 = oldDelta
                  | otherwise = annEntryDelta oldann
--    captured = annCapturedSpan


-- | A parent in this case is an element which has the same SrcSpan
findParent :: Data a => GHC.SrcSpan -> a -> Maybe AnnKey
findParent ss = something (findParentWorker ss)


findParentWorker :: forall a . (Typeable a, Data a)
           => GHC.SrcSpan -> a -> Maybe AnnKey
findParentWorker oldSS a
  | con == typeRepTyCon (typeRep (Proxy :: Proxy (GHC.Located GHC.RdrName))) && x == typeRep (Proxy :: Proxy GHC.SrcSpan)
      = if ss == oldSS
          then Just $ AnnKey ss cn
          else Nothing
  | otherwise = Nothing
  where
    (con, ~[x, y]) = splitTyConApp (typeOf a)
    ss :: GHC.SrcSpan
    ss = gmapQi 0 unsafeCoerce a
    cn = gmapQi 1 (CN . show . toConstr) a



{-
-- | Shift the first output annotation into the correct place
moveAnns :: [(KeywordId, DeltaPos)] -> [(KeywordId, DeltaPos)] -> [(KeywordId, DeltaPos)]
moveAnns [] xs        = xs
moveAnns _  []        = []
moveAnns ((_, dp): _) ((kw, _):xs) = (kw,dp) : xs
-}

-- | Perform the necessary adjustments to annotations when replacing
-- one Located thing with another Located thing.
--
-- For example, this function will ensure the correct relative position and
-- make sure that any trailing semi colons or commas are transferred.
modifyAnnKey :: (Data old, Data new) => Module -> Located old -> Located new -> M (Located new)
modifyAnnKey m e1 e2 = e2 <$ modify (\m -> replaceAnnKey m (mkAnnKey e1) (mkAnnKey e2) (mkAnnKey e2) parentKey)
  where
    parentKey = fromMaybe (mkAnnKey e2) (findParent (getLoc e2) m)


-- | Lower level version of @modifyAnnKey@
replaceAnnKey ::
  Anns -> AnnKey -> AnnKey -> AnnKey -> AnnKey -> Anns
replaceAnnKey a old new inp deltainfo =
  case replace old new inp deltainfo a  of
    Nothing -> a
    Just a' -> a'

-- | Convert a @Refact.Types.SrcSpan@ to a @SrcLoc.SrcSpan@
toGhcSrcSpan :: FilePath -> R.SrcSpan -> SrcSpan
toGhcSrcSpan file R.SrcSpan{..} = mkSrcSpan (f startLine startCol) (f endLine endCol)
  where
    f x y = mkSrcLoc (GHC.mkFastString file) x y
