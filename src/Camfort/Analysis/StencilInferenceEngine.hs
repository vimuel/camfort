{-# LANGUAGE DataKinds, GADTs, KindSignatures, TypeFamilies, FlexibleInstances, FlexibleContexts, NoMonomorphismRestriction, ScopedTypeVariables, PolyKinds #-}

module Camfort.Analysis.StencilInferenceEngine where

import Data.Generics.Uniplate.Operations
import Data.List
import Data.Data

import Camfort.Helpers
import Camfort.Helpers.Vec
import Debug.Trace

import Unsafe.Coerce

import Camfort.Analysis.StencilSpecs

{- Intervals are triples of lower, exact, upper values.
   If an exact value is available there is a possible fine-grained
   description as a list of 'a' -}   
type Interval a = (a, [a], a)

fst3 (a, b, c) = a
snd3 (a, b, c) = b
thd3 (a, b, c) = c

fromIndicesToSpec :: VecList Int -> Interval Specification
fromIndicesToSpec (VL ixs) = inferSpecInterval ixs

inferSpecInterval :: Permutable n => [Vec n Int] -> Interval Specification
inferSpecInterval ixs = (low, simplify exact, up)
  where (low, exact, up) = fromRegionsToSpecInterval . inferMinimalVectorRegions $ ixs

-- Simplifies lists specifications based on the 'specPlus', 'simplifyRefl' operations
simplify :: [Specification] -> [Specification]
simplify = normaliseBy specPlus . simplifyInsideProducts . simplifyRefl
  where simplifyInsideProducts = map (transformBi simplify)
  
-- Removes any 'reflexive' specs that are overlapped by a 'centered'
simplifyRefl :: [Specification] -> [Specification]
simplifyRefl sps = transformBi simplifyRefl' sps
  where
    simplifyRefl' (Product [s]) = s -- Only s
        
    simplifyRefl' (Only r@(Reflexive rdims))
      = case simplifyRefl' r of
          Empty -> Empty
          r     -> r --  Only r
          
    simplifyRefl' (Reflexive rdims) 
      = let rdims' = [d | (Symmetric _ dims) <- universeBi sps, d <- dims, d' <- rdims, d == d']
            rdimsF = [d | (Forward _ dims) <- universeBi sps, d <- dims, d' <- rdims, d == d']
            rdimsB = [d | (Backward _ dims) <- universeBi sps, d <- dims, d' <- rdims, d == d']
            
        in --TODO: Refactor this case- it is a bit over-the-top at the moment
           --(show ((rdims, rdims', rdimsF, rdimsB),(rdimsD,rdimsFD,rdimsBD))) `trace`
            case rdims \\ (rdims' ++ rdimsF ++ rdimsB) of
              [] -> Empty
              ds -> Reflexive ds
              
    simplifyRefl' s = s


fromRegionsToSpecInterval :: [Span (Vec n Int)] -> Interval Specification
fromRegionsToSpecInterval sps = (lower, exact, upper)
  where
    (lower, exact) = go sps
    upper          = head $ toSpecND $ foldl1 spanBoundingBox sps

    go []       = (Empty, [Empty])
    go [s]      = (Empty, toSpecND s)
   -- TODO, compute a better lower bound
    go (s : ss) = (lS, exact ++ eS)
      where exact    = toSpecND s
            (lS, eS) = go ss

-- toSpecND converts an n-dimensional region into a (list of) specification
--  The resulting list satisfies the following: 
--   the first element (if it exists) is a product of specifications
--   the second and successive elements (if they exists) are all reflexive specifications
toSpecND :: Span (Vec n Int) -> [Specification]
toSpecND n =
    case (toSpecPerDim n 1) of
      [s] -> [s] -- Previous "Only s" - TODO: figure out how much we need Only representation
      -- Take the product of the per-dimension specifications
      ss  -> Product nonRefls : refls
              where
                (refls, nonRefls) = partition (\x -> case x of { Reflexive _ -> True; _ -> False }) ss
  
-- convert the region one dimension at a time. 
toSpecPerDim :: Span (Vec n Int) -> Int -> [Specification]
toSpecPerDim (Nil, Nil)             d = []
toSpecPerDim (Cons l ls, Cons u us) d = (toSpec1D d l u) ++ (toSpecPerDim (ls, us) (d + 1))

-- : (toSpecification (dim+1) ms ns)

-- toSpec1D takes a dimension identifier, a lower and upper bound of a region in that dimension, and
-- builds the simple directional spec.
toSpec1D :: Dimension -> Int -> Int -> [Specification]
toSpec1D dim l u 
    | l == 0 && u == 0   = [Reflexive [dim]]
    | l==u               = [] -- Represents a non-span
    | l < 0 && u == 0    = [Backward (abs l) [dim], Reflexive [dim]]
    | l < 0 && u == (-1) = [Backward (abs l) [dim]]
    | l < 0 && u > 0 && (abs l == u)
                         = [Symmetric u [dim]]
    | l < 0 && u > 0 && (abs l /= u)
                         = [Backward (abs l) [dim], Forward u [dim], Reflexive [dim]]
    | l == 0 && u > 0    = [Forward u [dim]]
    | l == 1 && u > 0    = [Forward u [dim], Reflexive [dim]]
    | otherwise          = [Unspecified [dim]]


{- Spans are a pair of a lower and upper bound -}
type Span a = (a, a)
mkTrivialSpan a = (a, a)

{- Normalise a span into the form (lower, upper) based on the first index -}
normaliseSpan :: Span (Vec n Int) -> Span (Vec n Int)
normaliseSpan (Nil, Nil)
    = (Nil, Nil)
normaliseSpan (a@(Cons l1 ls1), b@(Cons u1 us1))
    | l1 <= u1  = (a, b)
    | otherwise = (b, a)

{- `spanBoundingBox` creates a span which is a bounding box over two spans -}
spanBoundingBox :: Span (Vec n Int) -> Span (Vec n Int) -> Span (Vec n Int)
spanBoundingBox a b = boundingBox' (normaliseSpan a) (normaliseSpan b)
  where
    boundingBox' :: Span (Vec n Int) -> Span (Vec n Int) -> Span (Vec n Int)
    boundingBox' (Nil, Nil) (Nil, Nil)
        = (Nil, Nil)
    boundingBox' (Cons l1 ls1, Cons u1 us1) (Cons l2 ls2, Cons u2 us2)
        = let (ls', us') = boundingBox' (ls1, us1) (ls2, us2)
           in (Cons (min l1 l2) ls', Cons (max u1 u2) us')


{-| Given two spans, if they are consecutive
    (i.e., (lower1, upper1) (lower2, upper2) where lower2 = upper1 + 1)
    then compose them together returning Just of the new span. Otherwise Nothing -}
composeConsecutiveSpans :: Span (Vec n Int) -> Span (Vec n Int) -> Maybe (Span (Vec n Int))
composeConsecutiveSpans (Nil, Nil) (Nil, Nil) = Just (Nil, Nil)
composeConsecutiveSpans x@(Cons l1 ls1, Cons u1 us1) y@(Cons l2 ls2, Cons u2 us2)
    | (ls1 == ls2) && (us1 == us2) && (u1 + 1 == l2)  
      = Just (Cons l1 ls1, Cons u2 us2)
    | otherwise
      = Nothing

foobar = [Cons 0 (Cons 1 Nil), Cons 1 (Cons 1 Nil)]

{-| |inferMinimalVectorRegions| a key part of the algorithm, from a list of n-dimensional relative indices 
    it infers a list of (possibly overlapping) 1-dimensional spans (vectors) within the n-dimensional space.
    Built from |minimalise| and |allRegionPermutations| -}
inferMinimalVectorRegions :: (Permutable n) => [Vec n Int] -> [Span (Vec n Int)]
inferMinimalVectorRegions = fixCoalesce . map mkTrivialSpan
  where fixCoalesce spans = let spans' = minimaliseRegions . allRegionPermutations $ spans
                            in if spans' == spans then spans' else fixCoalesce spans'

{-| Map from a lists of n-dimensional spans of relative indices into all possible
    contiguous spans within that n-dimensional space (individual pass) -}    
allRegionPermutations :: (Permutable n) => [Span (Vec n Int)] -> [[Span (Vec n Int)]]
allRegionPermutations =
    unpermuteIndices . map (coalesceRegions >< id) . groupByPerm . map permutationsS
    where
      {- Permutations of a indices in a span 
         (independently permutes the lower and upper bounds in the same way) -}
      permutationsS :: Permutable n => Span (Vec n Int) -> [(Span (Vec n Int), (Vec n Int) -> (Vec n Int))]
      -- Since the permutation ordering is identical for lower & upper bound,
      -- reuse the same unpermutation
      permutationsS (l, u) = map (\((l', un1), (u', un2)) -> ((l', u'), un1))
                           $ zip (permutationsV l) (permutationsV u)

      sortByFst        = (sortBy (\(l1, u1) (l2, u2) -> compare l1 l2))
      
      groupByPerm      = map (\ixP -> let unPerm = snd $ head ixP
                                      in (map fst ixP, unPerm)) . transpose

      coalesceRegions :: [Span (Vec n Int)] -> [Span (Vec n Int)]
      coalesceRegions  = foldPair composeConsecutiveSpans . sortByFst

      unpermuteIndices :: [([Span (Vec n Int)], Vec n Int -> Vec n Int)]
                       -> [[Span (Vec n Int)]]
      unpermuteIndices = map (\(rs, unPerm) -> map (\(l, u) -> (unPerm l, unPerm u)) rs)

{-| Collapses the regions into a small set by looking for potential overlaps and eliminating those
    that overlap -}
minimaliseRegions :: [[Span (Vec n Int)]] -> [Span (Vec n Int)] 
minimaliseRegions [] = []
minimaliseRegions xss = nub $ go xss'
  where xss' = concat xss
        go []     = []
        go (x:xs) = (filter' x (\y -> overlaps x y && (x /= y)) xss') ++ (go xs)
        -- If nothing is caught by the filter, i.e. no overlaps then return the original regions r
        filter' r f xs = case (filter f xs) of
                           [] -> [r]
                           ys -> ys
                           
{-| Binary predicate on whether the first region overlaps the second -}
overlaps :: Span (Vec n Int) -> Span (Vec n Int) -> Bool
overlaps (Nil, Nil) (Nil, Nil) 
  = True
overlaps (Cons l1 ls1, Cons u1 us1) (Cons l2 ls2, Cons u2 us2) 
  = if (l2 <= l1 && u1 <= u2)
    then overlaps (ls1, us1) (ls2, us2)
    else False

      
{-| Defines the (total) class of vector sizes which are permutable, along with the
     permutation function which pairs permutations with the 'unpermute' operation -}
class Permutable (n :: Nat) where
  -- From a Vector of length n to a list of 'selections'
  --   (triples of a selected element, the rest of the vector, a function to 'unselect')
  selectionsV :: Vec n a -> [Selection n a]
  -- From a Vector of length n to a list of its permutations paired with the 'unpermute' function
  permutationsV :: Vec n a -> [(Vec n a, Vec n a -> Vec n a)]

-- 'Split' is a size-indexed family which gives the type of selections
-- for each size:
--    Z is trivial
--    (S n) provides a triple of the select element, the remaining vector,
--           and the 'unselect' function for returning the original value
type family Selection n a where
            Selection Z a = a
            Selection (S n) a = (a, Vec n a, a -> Vec n a -> Vec (S n) a)

instance Permutable Z where
  selectionsV Nil   = []
  permutationsV Nil = []
  
instance Permutable (S Z) where
  selectionsV (Cons x xs)
    = [(x, Nil, Cons)]
  permutationsV (Cons x Nil)
    = [(Cons x Nil, id)]

instance Permutable (S n) => Permutable (S (S n)) where
  selectionsV (Cons x xs)
    = (x, xs, Cons) : [ (y, Cons x ys, unselect unSel) | (y, ys, unSel) <- selectionsV xs]
    where
      unselect :: (a -> Vec n a -> Vec (S n) a) -> (a -> Vec (S n) a -> Vec (S (S n)) a)
      unselect f y' (Cons x' ys') = Cons x' (f y' ys')

  permutationsV xs =
      [ (Cons y zs, \(Cons y' zs') -> (unSel y') (unPerm zs')) 
        | (y, ys, unSel) <- selectionsV xs,
          (zs,  unPerm)  <- permutationsV ys ]

{- Vector list repreentation where the size 'n' is existential quantified -}
data VecList a where VL :: Permutable n => [Vec n a] -> VecList a

-- Lists existentially quanitify over a vector's size : Exists n . Vec n a 
data List a where
     List :: Permutable n => Vec n a -> List a
     
lnil :: List a
lnil = List Nil
lcons :: a -> List a -> List a
lcons x (List Nil) = List (Cons x Nil)
lcons x (List (Cons y Nil)) = List (Cons x (Cons y Nil))
lcons x (List (Cons y (Cons z xs))) = List (Cons x (Cons y (Cons z xs)))

fromList :: [a] -> List a
fromList []       = lnil
fromList (x : xs) = lcons x (fromList xs)

-- pre-condition: the input is a 'rectangular' list of lists (i.e. all internal lists have the same size)
fromLists :: [[Int]] -> VecList Int
fromLists [] = VL ([] :: [Vec Z Int])
fromLists (xs:xss) = consList (fromList xs) (fromLists xss)
  where
    consList :: List Int -> VecList Int -> VecList Int
    consList (List vec) (VL [])     = VL [vec]
    consList (List vec) (VL (x:xs))
      = let (vec', x') = zipVec vec x
        in  -- Force the pre-condition equality 
          case (preCondition x' xs, preCondition vec' xs) of
            (ReflEq, ReflEq) -> VL $ (vec' : (x' : xs))
                
            where -- At the moment the pre-condition is 'assumed', and therefore
              -- force used unsafeCoerce: TODO, rewrite
              preCondition :: Vec n a -> [Vec n1 a] -> EqT n n1
              preCondition xs x = unsafeCoerce $ ReflEq

-- Equality type
data EqT (a :: k) (b :: k) where
    ReflEq :: EqT a a
        