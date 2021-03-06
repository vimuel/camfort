{-
   Copyright 2016, Dominic Orchard, Andrew Rice, Mistral Contrastin, Matthew Danish

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE CPP #-}

module Camfort.Helpers where

import GHC.Generics
import Data.Generics.Zipper
import Data.Generics.Aliases
import Data.Generics.Uniplate.Operations
import qualified Data.Generics.Str as Str
import Data.Data
import Data.Maybe
import Data.Monoid
import Data.List (elemIndices, group, sort, nub)
import qualified Data.ByteString.Char8 as B
import System.Directory
import Data.List (union)
import qualified Data.Map.Lazy as Map hiding (map, (\\))
import Control.Monad.Writer.Strict

-- collect: from an association list to a map with list-based bins for matching keys
collect :: (Eq a, Ord k) => [(k, a)] -> Map.Map k [a]
collect = Map.fromListWith union . map (fmap (:[]))

type Filename = String
type Directory = String
type SourceText = B.ByteString
type FileOrDir = String

-- Filename and directory related helpers

-- gets the directory part of a filename
getDir :: String -> String
getDir file = let ixs = elemIndices '/' file
              in if null ixs then file
                 else take (last $ ixs) file


{-| Creates a directory (from a filename string) if it doesn't exist -}
checkDir f = case (elemIndices '/' f) of
               [] -> return ()
               ix -> let d = take (last ix) f
                     in createDirectoryIfMissing True d

isDirectory :: FileOrDir -> IO Bool
isDirectory s = doesDirectoryExist s

-- Helpers
fanout :: (a -> b) -> (a -> c) -> a -> (b, c)
fanout f g x = (f x, g x)

(<>) :: (a -> b) -> (a -> c) -> a -> (b, c)
f <> g = fanout f g

(><) :: (a -> c) -> (b -> d) -> (a, b) -> (c, d)
f >< g = \(x, y) -> (f x, g y)

-- Lookup functions over relation s

lookups :: Eq a => a -> [(a, b)] -> [b]
lookups _ [] = []
lookups x ((a, b):xs) = if (x == a) then b : lookups x xs
                                    else lookups x xs

lookups' :: Eq a => a -> [((a, b), c)] -> [(b, c)]
lookups' _ [] = []
lookups' x (((a, b), c):xs) = if (x == a) then (b, c) : lookups' x xs
                                          else lookups' x xs

{-| Computes all pairwise combinations -}
pairs :: [a] -> [(a, a)]
pairs []     = []
pairs (x:xs) = (zip (repeat x) xs) ++ (pairs xs)

{-| Functor composed with list functor -}
mfmap :: Functor f => (a -> b) -> [f a] -> [f b]
mfmap f = map (fmap f)

{-| An infix `map` operation.-}
each = flip (map)

{-| Is the Ordering an EQ? -}
cmpEq :: Ordering -> Bool
cmpEq EQ = True
cmpEq _  = False

cmpFst :: (a -> a -> Ordering) -> (a, b) -> (a, b) -> Ordering
cmpFst c (x1, y1) (x2, y2) = c x1 x2

cmpSnd :: (b -> b -> Ordering) -> (a, b) -> (a, b) -> Ordering
cmpSnd c (x1, y1) (x2, y2) = c y1 y2

{-| used for type-level annotations giving documentation -}
type (:?) a (b :: k) = a

-- Helper function, reduces a list two elements at a time with a partial operation
foldPair :: (a -> a -> Maybe a) -> [a] -> [a]
foldPair f [] = []
foldPair f [a] = [a]
foldPair f (a:(b:xs)) = case f a b of
                          Nothing -> a : (foldPair f (b : xs))
                          Just c  -> foldPair f (c : xs)


class PartialMonoid x where
  -- Satisfies equations:
   --   pmappend x pmempty = Just x
   --   pmappend pempty x  = Just x
   --   (pmappend y z) >>= (\w -> pmappend x w) = (pmappend x y) >>= (\w -> pmappend w z)

   emptyM  :: x
   appendM :: x -> x -> Maybe x

normalise :: (Ord t, PartialMonoid t) => [t] -> [t]
normalise = nub . reduce . sort
  where reduce = foldPair appendM

normaliseNoSort :: (Ord t, PartialMonoid t) => [t] -> [t]
normaliseNoSort = nub . reduce
  where reduce = foldPair appendM

normaliseBy :: Ord t => (t -> t -> Maybe t) -> [t] -> [t]
normaliseBy plus = nub . (foldPair plus) . sort

#if __GLASGOW_HASKELL__ < 800
instance Monoid x => Monad ((,) x) where
    return a = (mempty, a)
    (x, a) >>= k = let (x', b) = k a
                   in (mappend x x', b)
#endif

-- Data-type generic reduce traversal
reduceCollect :: (Data s, Data t, Uniplate t, Biplate t s) => (s -> Maybe a) -> t -> [a]
reduceCollect k x = execWriter (transformBiM (\y -> do case k y of
                                                         Just x -> tell [x]
                                                         Nothing -> return ()
                                                       return y) x)

-- Data-type generic comonad-style traversal with zipper (contextual traversal)
everywhere :: (Zipper a -> Zipper a) -> Zipper a -> Zipper a
everywhere k z = everywhere' z
  where
    everywhere' = enterRight . enterDown . k

    enterDown z =
        case (down' z) of
          Just dz -> let dz' = everywhere' dz
                     in case (up $ dz') of
                          Just uz -> uz
                          Nothing -> dz'
          Nothing -> z

    enterRight z =
         case (right z) of
           Just rz -> let rz' = everywhere' rz
                      in case (left $ rz') of
                           Just lz -> lz
                           Nothing -> rz'
           Nothing -> z


zfmap :: Data a => (a -> a) -> Zipper (d a) -> Zipper (d a)
zfmap f x = zeverywhere (mkT f) x

-- Data-generic generic descend but processes children in reverse order
-- (good for backwards analysis)
data Reverse f a = Reverse { unwrapReverse :: f a }

instance Functor (Reverse Str.Str) where
    fmap f (Reverse s) = Reverse (fmap f s)

instance Foldable (Reverse Str.Str) where
    foldMap f (Reverse x) = foldMap f x

instance Traversable (Reverse Str.Str) where
    traverse f (Reverse Str.Zero) = pure $ Reverse Str.Zero
    traverse f (Reverse (Str.One x)) = (Reverse . Str.One) <$> f x
    traverse f (Reverse (Str.Two x y)) = (\y x -> Reverse $ Str.Two x y)
                             <$> (fmap unwrapReverse . traverse f . Reverse $ y)
                             <*> (fmap unwrapReverse . traverse f . Reverse $ x)


-- Custom version of descend that process tree in reverse order
descendReverseM :: (Data on, Monad m, Uniplate on) => (on -> m on) -> on -> m on
descendReverseM f x =
    liftM generate . fmap unwrapReverse . traverse f . Reverse $ current
  where (current, generate) = uniplate x

descendBiReverseM :: (Data from, Data to, Monad m, Biplate from to) => (to -> m to) -> from -> m from
descendBiReverseM f x =
    liftM generate . fmap unwrapReverse . traverse f . Reverse $ current
  where (current, generate) = biplate x