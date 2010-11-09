{-# LANGUAGE CPP #-}
-- |
-- Module      : Data.Array.Accelerate.Prelude
-- Copyright   : [2010] Manuel M T Chakravarty, Ben Lever
-- License     : BSD3
--
-- Maintainer  : Manuel M T Chakravarty <chak@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Standard functions that are not part of the core set (directly represented in the AST), but are
-- instead implemented in terms of the core set.

module Data.Array.Accelerate.Prelude (

  -- ** Map-like
  zip, unzip,
  
  -- ** Scans
  prescanl, postscanl, prescanr, postscanr, 

  -- ** Segmented scans
  scanlSeg, scanlSeg', scanl1Seg, prescanlSeg, postscanlSeg, 
  scanrSeg, scanrSeg', scanr1Seg, prescanrSeg, postscanrSeg
  
) where

-- avoid clashes with Prelude functions
import Prelude   hiding (replicate, zip, unzip, map, scanl, scanl1, scanr, scanr1, zipWith,
                         filter, max, min, not, const, fst, snd, curry, uncurry)
import qualified Prelude

-- friends  
import Data.Array.Accelerate.Array.Sugar hiding ((!), ignore, shape)
import Data.Array.Accelerate.Language

#include "accelerate.h"


-- Map-like composites
-- -------------------

-- |Combine the elements of two arrays pairwise.  The shape of the result is 
-- the intersection of the two argument shapes.
--
zip :: (Ix dim, Elem a, Elem b) 
    => Acc (Array dim a)
    -> Acc (Array dim b)
    -> Acc (Array dim (a, b))
zip = zipWith (\x y -> tuple (x, y))

-- |The converse of 'zip', but the shape of the two results is identical to the
-- shape of the argument.
-- 
unzip :: (Ix dim, Elem a, Elem b)
      => Acc (Array dim (a, b))
      -> (Acc (Array dim a), Acc (Array dim b))
unzip arr = (map fst arr, map snd arr)


-- Composite scans
-- ---------------

-- |Left-to-right prescan (aka exclusive scan).  As for 'scan', the first argument must be an
-- /associative/ function.  Denotationally, we have
--
-- > prescanl f e = Prelude.fst . scanl' f e
--
prescanl :: Elem a
         => (Exp a -> Exp a -> Exp a)
         -> Exp a
         -> Acc (Vector a)
         -> Acc (Vector a)
prescanl f e = Prelude.fst . scanl' f e

-- |Left-to-right postscan, a variant of 'scanl1' with an initial value.  Denotationally, we have
--
-- > postscanl f e = map (e `f`) . scanl1 f
--
postscanl :: Elem a
          => (Exp a -> Exp a -> Exp a)
          -> Exp a
          -> Acc (Vector a)
          -> Acc (Vector a)
postscanl f e = map (e `f`) . scanl1 f

-- |Right-to-left prescan (aka exclusive scan).  As for 'scan', the first argument must be an
-- /associative/ function.  Denotationally, we have
--
-- > prescanr f e = Prelude.fst . scanr' f e
--
prescanr :: Elem a
         => (Exp a -> Exp a -> Exp a)
         -> Exp a
         -> Acc (Vector a)
         -> Acc (Vector a)
prescanr f e = Prelude.fst . scanr' f e

-- |Right-to-left postscan, a variant of 'scanr1' with an initial value.  Denotationally, we have
--
-- > postscanr f e = map (e `f`) . scanr1 f
--
postscanr :: Elem a
          => (Exp a -> Exp a -> Exp a)
          -> Exp a
          -> Acc (Vector a)
          -> Acc (Vector a)
postscanr f e = map (`f` e) . scanr1 f


-- Segmented scans
-- ---------------

-- |Segmented version of 'scanl'.
--
scanlSeg :: Elem a
         => (Exp a -> Exp a -> Exp a)
         -> Exp a
         -> Acc (Vector a)
         -> Acc Segments
         -> Acc (Vector a)
scanlSeg f e arr seg = scans
  where
    -- Segmented scan implemented by performing segmented exclusive-scan (scan1)
    -- on a vector formed by injecting the identity element at the start of each
    -- segment.
    scans     = scanl1Seg f idInjArr seg'
    seg'      = map (+ 1) seg
    idInjArr  = permute f idsArr (\ix -> ix + (offsetArr ! ix) + 1) arr
    idsArr    = replicate n $ unit e
    n         = (shape arr) + (shape seg)

    -- As the identity elements are injected in to the vector for each segment, the
    -- remaining elemnets must be shifted forwarded (to the left). offsetArr specifies
    -- by how much each element is shifted.
    offsetArr = scanl1 (max) $ permute (+) zerosArr (\ix -> segOffsets ! ix) segIxs
    zerosArr  = replicate (shape arr) $ unit 0

    segOffsets = Prelude.fst $ scanl' (+) 0 seg
    segIxs     = Prelude.fst $ scanl' (+) 0 $ replicate (shape seg) $ unit 1

-- |Segmented version of 'scanl\''.
--
-- The first element of the resulting tuple is a vector of scanned values. The
-- second element is a vector of segment scan totals and has the same size as
-- the segment vector.
--
scanlSeg' :: Elem a
          => (Exp a -> Exp a -> Exp a)
          -> Exp a
          -> Acc (Vector a)
          -> Acc Segments
          -> (Acc (Vector a), Acc (Vector a))
scanlSeg' f e arr seg = (scans, sums)
  where
    -- Segmented scan' implemented by performing segmented exclusive-scan on vector
    -- fromed by inserting identity element in at the start of each segment, shifting
    -- elements right, with the final element in the segment being removed.
    scans     = scanl1Seg f idShftArr seg
    idShftArr = permute f idsArr 
                  (\ix -> (((mkTailFlags seg) ! ix) ==* 1) ? (ignore, ix + 1))
                  arr
    idsArr    = replicate (shape arr) $ unit e

    -- Sum of each segment is computed by performing a segmented postscan on
    -- the original vector and taking the tail elements.
    sums       = backpermute (shape seg) (\ix -> sumOffsets ! ix) $ 
                   scanl1Seg f arr seg
    sumOffsets = map (\v -> v - 1) $ scanl1 (+) seg

-- |Segmented version of 'scanl1'.
--
scanl1Seg :: Elem a
          => (Exp a -> Exp a -> Exp a)
          -> Acc (Vector a)
          -> Acc Segments
          -> Acc (Vector a)
scanl1Seg f arr seg = map snd $ scanl1 (mkSegApply f) $ zip (mkHeadFlags seg) arr

-- |Segmented version of 'prescanl'.
--
prescanlSeg :: Elem a
            => (Exp a -> Exp a -> Exp a)
            -> Exp a
            -> Acc (Vector a)
            -> Acc Segments
            -> Acc (Vector a)
prescanlSeg f e arr seg = Prelude.fst $ scanlSeg' f e arr seg

-- |Segmented version of 'postscanl'.
--
postscanlSeg :: Elem a
             => (Exp a -> Exp a -> Exp a)
             -> Exp a
             -> Acc (Vector a)
             -> Acc Segments
             -> Acc (Vector a)
postscanlSeg f e arr seg = map (e `f`) $ scanl1Seg f arr seg

-- |Segmented version of 'scanr'.
--
scanrSeg :: Elem a
         => (Exp a -> Exp a -> Exp a)
         -> Exp a
         -> Acc (Vector a)
         -> Acc Segments
         -> Acc (Vector a)
scanrSeg f e arr seg = scans
  where
    -- Using technique described for scanlSeg.
    scans     = scanr1Seg f idInjArr seg'
    seg'      = map (+ 1) seg
    idInjArr  = permute f idsArr (\ix -> ix + (offsetArr ! ix)) arr
    idsArr    = replicate n $ unit e
    n         = (shape arr) + (shape seg)

    --
    offsetArr = scanl1 (max) $ permute (+) zerosArr (\ix -> segOffsets ! ix) segIxs
    zerosArr  = replicate (shape arr) $ unit 0

    segOffsets = Prelude.fst $ scanl' (+) 0 seg
    segIxs     = Prelude.fst $ scanl' (+) 0 $ replicate (shape seg) $ unit 1

-- |Segmented version of 'scanrSeg\''.
--
scanrSeg' :: Elem a
            => (Exp a -> Exp a -> Exp a)
            -> Exp a
            -> Acc (Vector a)
            -> Acc Segments
            -> (Acc (Vector a), Acc (Vector a))
scanrSeg' f e arr seg = (scans, sums)
  where
    -- Using technique described for scanlSeg'.
    scans     = scanr1Seg f idShftArr seg
    idShftArr = permute f idsArr 
                  (\ix -> (((mkHeadFlags seg) ! ix) ==* 1) ? (ignore, ix - 1))
                  arr
    idsArr    = replicate (shape arr) $ unit e

    --
    sums       = backpermute (shape seg) (\ix -> sumOffsets ! ix) $ 
                   scanr1Seg f arr seg
    sumOffsets = Prelude.fst $ scanl' (+) 0 seg

-- |Segmented version of 'scanr1'.
--
scanr1Seg :: Elem a
          => (Exp a -> Exp a -> Exp a)
          -> Acc (Vector a)
          -> Acc Segments
          -> Acc (Vector a)
scanr1Seg f arr seg = map snd $ scanr1 (mkSegApply f) $ zip (mkTailFlags seg) arr

-- |Segmented version of 'prescanr'.
--
prescanrSeg :: Elem a
            => (Exp a -> Exp a -> Exp a)
            -> Exp a
            -> Acc (Vector a)
            -> Acc Segments
            -> Acc (Vector a)
prescanrSeg f e arr seg = Prelude.fst $ scanrSeg' f e arr seg

-- |Segmented version of 'postscanr'.
--
postscanrSeg :: Elem a
             => (Exp a -> Exp a -> Exp a)
             -> Exp a
             -> Acc (Vector a)
             -> Acc Segments
             -> Acc (Vector a)
postscanrSeg f e arr seg = map (`f` e) $ scanr1Seg f arr seg


-- Segmented scan helpers
-- ----------------------

-- |Compute head flags vector from segment vector for left-scans.
--
mkHeadFlags :: Acc (Array DIM1 Int) -> Acc (Array DIM1 Int)
mkHeadFlags seg = permute (\_ _ -> 1) zerosArr (\ix -> segOffsets ! ix) segOffsets
  where
    (segOffsets, len) = scanl' (+) 0 seg
    zerosArr          = replicate (len ! (constant ())) $ unit 0


-- |Compute tail flags vector from segment vector for right-scans.
--
mkTailFlags :: Acc (Array DIM1 Int) -> Acc (Array DIM1 Int)
mkTailFlags seg
  = permute (\_ _ -> 1) zerosArr (\ix -> (segOffsets ! ix) - 1) segOffsets
  where
    segOffsets = scanl1 (+) seg
    len        = segOffsets ! ((shape seg) - 1)
    zerosArr   = replicate len $ unit 0


-- |Construct a segmented version of apply from a non-segmented version. The segmented apply
-- operates on a head-flag value tuple.
--
mkSegApply :: (Elem e)
         => (Exp e -> Exp e -> Exp e)
         -> (Exp (Int, e) -> Exp (Int, e) -> Exp (Int, e))
mkSegApply op = apply
  where
    apply a b = tuple (((aF ==* 1) ||* (bF ==* 1)) ? (1, 0), (bF ==* 1) ? (bV, aV `op` bV))
      where
        aF = fst a
        aV = snd a
        bF = fst b
        bV = snd b