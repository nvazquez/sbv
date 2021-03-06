-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Core.Concrete
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Operations on concrete values
-----------------------------------------------------------------------------

module Data.SBV.Core.Concrete
  ( module Data.SBV.Core.Concrete
  ) where

import Control.Monad (replicateM)

import Data.Bits
import System.Random (randomIO, randomRIO)

import Data.Char (chr)
import Data.List (isPrefixOf, intercalate)

import Data.SBV.Core.Kind
import Data.SBV.Core.AlgReals

import Data.SBV.Utils.Numeric (fpIsEqualObjectH, fpCompareObjectH)

-- | A constant value
data CWVal = CWAlgReal  !AlgReal              -- ^ algebraic real
           | CWInteger  !Integer              -- ^ bit-vector/unbounded integer
           | CWFloat    !Float                -- ^ float
           | CWDouble   !Double               -- ^ double
           | CWChar     !Char                 -- ^ character
           | CWString   !String               -- ^ string
           | CWList     ![CWVal]              -- ^ list
           | CWUserSort !(Maybe Int, String)  -- ^ value of an uninterpreted/user kind. The Maybe Int shows index position for enumerations

-- | Assing a rank to CW Values, this is structural and helps with ordering
cwRank :: CWVal -> Int
cwRank CWAlgReal  {} = 0
cwRank CWInteger  {} = 1
cwRank CWFloat    {} = 2
cwRank CWDouble   {} = 3
cwRank CWChar     {} = 4
cwRank CWString   {} = 5
cwRank CWList     {} = 6
cwRank CWUserSort {} = 7

-- | Eq instance for CWVal. Note that we cannot simply derive Eq/Ord, since CWAlgReal doesn't have proper
-- instances for these when values are infinitely precise reals. However, we do
-- need a structural eq/ord for Map indexes; so define custom ones here:
instance Eq CWVal where
  CWAlgReal  a == CWAlgReal  b = a `algRealStructuralEqual` b
  CWInteger  a == CWInteger  b = a == b
  CWFloat    a == CWFloat    b = a `fpIsEqualObjectH` b   -- We don't want +0/-0 to be confused; and also we want NaN = NaN here!
  CWDouble   a == CWDouble   b = a `fpIsEqualObjectH` b   -- ditto
  CWChar     a == CWChar     b = a == b
  CWString   a == CWString   b = a == b
  CWList     a == CWList     b = a == b
  CWUserSort a == CWUserSort b = a == b
  _            == _            = False

-- | Ord instance for CWVal. Same comments as the 'Eq' instance why this cannot be derived.
instance Ord CWVal where
  CWAlgReal  a `compare` CWAlgReal b  = a        `algRealStructuralCompare` b
  CWInteger  a `compare` CWInteger b  = a        `compare`                  b
  CWFloat    a `compare` CWFloat b    = a        `fpCompareObjectH`         b
  CWDouble   a `compare` CWDouble b   = a        `fpCompareObjectH`         b
  CWChar     a `compare` CWChar b     = a        `compare`                  b
  CWString   a `compare` CWString b   = a        `compare`                  b
  CWList     a `compare` CWList   b   = a        `compare`                  b
  CWUserSort a `compare` CWUserSort b = a        `compare`                  b
  a            `compare` b            = cwRank a `compare`                  cwRank b

-- | 'CW' represents a concrete word of a fixed size:
-- For signed words, the most significant digit is considered to be the sign.
data CW = CW { _cwKind  :: !Kind
             , cwVal    :: !CWVal
             }
        deriving (Eq, Ord)

-- | A generalized CW allows for expressions involving infinite and epsilon values/intervals Used in optimization problems.
data GeneralizedCW = ExtendedCW ExtCW
                   | RegularCW  CW

-- | A simple expression type over extendent values, covering infinity, epsilon and intervals.
data ExtCW = Infinite  Kind         -- infinity
           | Epsilon   Kind         -- epsilon
           | Interval  ExtCW ExtCW  -- closed interval
           | BoundedCW CW           -- a bounded value (i.e., neither infinity, nor epsilon). Note that this cannot appear at top, but can appear as a sub-expr.
           | AddExtCW  ExtCW ExtCW  -- addition
           | MulExtCW  ExtCW ExtCW  -- multiplication

-- | Kind instance for Extended CW
instance HasKind ExtCW where
  kindOf (Infinite  k)   = k
  kindOf (Epsilon   k)   = k
  kindOf (Interval  l _) = kindOf l
  kindOf (BoundedCW  c)  = kindOf c
  kindOf (AddExtCW  l _) = kindOf l
  kindOf (MulExtCW  l _) = kindOf l

-- | Show instance, shows with the kind
instance Show ExtCW where
  show = showExtCW True

-- | Show an extended CW, with kind if required
showExtCW :: Bool -> ExtCW -> String
showExtCW = go False
  where go parens shk extCW = case extCW of
                                Infinite{}    -> withKind False "oo"
                                Epsilon{}     -> withKind False "epsilon"
                                Interval  l u -> withKind True  $ '['  : showExtCW False l ++ " .. " ++ showExtCW False u ++ "]"
                                BoundedCW c   -> showCW shk c
                                AddExtCW l r  -> par $ withKind False $ add (go True False l) (go True False r)

                                -- a few niceties here to grok -oo and -epsilon
                                MulExtCW (BoundedCW (CW KUnbounded (CWInteger (-1)))) Infinite{} -> withKind False "-oo"
                                MulExtCW (BoundedCW (CW KReal      (CWAlgReal (-1)))) Infinite{} -> withKind False "-oo"
                                MulExtCW (BoundedCW (CW KUnbounded (CWInteger (-1)))) Epsilon{}  -> withKind False "-epsilon"
                                MulExtCW (BoundedCW (CW KReal      (CWAlgReal (-1)))) Epsilon{}  -> withKind False "-epsilon"

                                MulExtCW l r  -> par $ withKind False $ mul (go True False l) (go True False r)
           where par v | parens = '(' : v ++ ")"
                       | True   = v
                 withKind isInterval v | not shk    = v
                                       | isInterval = v ++ " :: [" ++ showBaseKind (kindOf extCW) ++ "]"
                                       | True       = v ++ " :: "  ++ showBaseKind (kindOf extCW)

                 add :: String -> String -> String
                 add n v
                  | "-" `isPrefixOf` v = n ++ " - " ++ tail v
                  | True               = n ++ " + " ++ v

                 mul :: String -> String -> String
                 mul n v = n ++ " * " ++ v

-- | Is this a regular CW?
isRegularCW :: GeneralizedCW -> Bool
isRegularCW RegularCW{}  = True
isRegularCW ExtendedCW{} = False

-- | 'Kind' instance for CW
instance HasKind CW where
  kindOf (CW k _) = k

-- | 'Kind' instance for generalized CW
instance HasKind GeneralizedCW where
  kindOf (ExtendedCW e) = kindOf e
  kindOf (RegularCW  c) = kindOf c

-- | Are two CW's of the same type?
cwSameType :: CW -> CW -> Bool
cwSameType x y = kindOf x == kindOf y

-- | Convert a CW to a Haskell boolean (NB. Assumes input is well-kinded)
cwToBool :: CW -> Bool
cwToBool x = cwVal x /= CWInteger 0

-- | Normalize a CW. Essentially performs modular arithmetic to make sure the
-- value can fit in the given bit-size. Note that this is rather tricky for
-- negative values, due to asymmetry. (i.e., an 8-bit negative number represents
-- values in the range -128 to 127; thus we have to be careful on the negative side.)
normCW :: CW -> CW
normCW c@(CW (KBounded signed sz) (CWInteger v)) = c { cwVal = CWInteger norm }
 where norm | sz == 0 = 0
            | signed  = let rg = 2 ^ (sz - 1)
                        in case divMod v rg of
                                  (a, b) | even a -> b
                                  (_, b)          -> b - rg
            | True    = v `mod` (2 ^ sz)
normCW c@(CW KBool (CWInteger v)) = c { cwVal = CWInteger (v .&. 1) }
normCW c = c

-- | Constant False as a CW. We represent it using the integer value 0.
falseCW :: CW
falseCW = CW KBool (CWInteger 0)

-- | Constant True as a CW. We represent it using the integer value 1.
trueCW :: CW
trueCW  = CW KBool (CWInteger 1)

-- | Lift a unary function through a CW
liftCW :: (AlgReal -> b) -> (Integer -> b) -> (Float -> b) -> (Double -> b) -> (Char -> b) -> (String -> b) -> ((Maybe Int, String) -> b) -> ([CWVal] -> b) -> CW -> b
liftCW f _ _ _ _ _ _ _ (CW _ (CWAlgReal  v)) = f v
liftCW _ f _ _ _ _ _ _ (CW _ (CWInteger  v)) = f v
liftCW _ _ f _ _ _ _ _ (CW _ (CWFloat    v)) = f v
liftCW _ _ _ f _ _ _ _ (CW _ (CWDouble   v)) = f v
liftCW _ _ _ _ f _ _ _ (CW _ (CWChar     v)) = f v
liftCW _ _ _ _ _ f _ _ (CW _ (CWString   v)) = f v
liftCW _ _ _ _ _ _ f _ (CW _ (CWUserSort v)) = f v
liftCW _ _ _ _ _ _ _ f (CW _ (CWList     v)) = f v

-- | Lift a binary function through a CW
liftCW2 :: (AlgReal -> AlgReal -> b) -> (Integer -> Integer -> b) -> (Float -> Float -> b) -> (Double -> Double -> b) -> (Char -> Char -> b) -> (String -> String -> b) -> ([CWVal] -> [CWVal] -> b) -> ((Maybe Int, String) -> (Maybe Int, String) -> b) -> CW -> CW -> b
liftCW2 r i f d c s u v x y = case (cwVal x, cwVal y) of
                                (CWAlgReal  a, CWAlgReal  b) -> r a b
                                (CWInteger  a, CWInteger  b) -> i a b
                                (CWFloat    a, CWFloat    b) -> f a b
                                (CWDouble   a, CWDouble   b) -> d a b
                                (CWChar     a, CWChar     b) -> c a b
                                (CWString   a, CWString   b) -> s a b
                                (CWList     a, CWList     b) -> u a b
                                (CWUserSort a, CWUserSort b) -> v a b
                                _                            -> error $ "SBV.liftCW2: impossible, incompatible args received: " ++ show (x, y)

-- | Map a unary function through a CW.
mapCW :: (AlgReal -> AlgReal) -> (Integer -> Integer) -> (Float -> Float) -> (Double -> Double) -> (Char -> Char) -> (String -> String) -> ((Maybe Int, String) -> (Maybe Int, String)) -> CW -> CW
mapCW r i f d c s u x  = normCW $ CW (kindOf x) $ case cwVal x of
                                                    CWAlgReal  a -> CWAlgReal  (r a)
                                                    CWInteger  a -> CWInteger  (i a)
                                                    CWFloat    a -> CWFloat    (f a)
                                                    CWDouble   a -> CWDouble   (d a)
                                                    CWChar     a -> CWChar     (c a)
                                                    CWString   a -> CWString   (s a)
                                                    CWUserSort a -> CWUserSort (u a)
                                                    CWList{}     -> error "Data.SBV.mapCW: Unexpected call through mapCW with lists!"

-- | Map a binary function through a CW.
mapCW2 :: (AlgReal -> AlgReal -> AlgReal) -> (Integer -> Integer -> Integer) -> (Float -> Float -> Float) -> (Double -> Double -> Double) -> (Char -> Char -> Char) -> (String -> String -> String) -> ((Maybe Int, String) -> (Maybe Int, String) -> (Maybe Int, String)) -> CW -> CW -> CW
mapCW2 r i f d c s u x y = case (cwSameType x y, cwVal x, cwVal y) of
                            (True, CWAlgReal  a, CWAlgReal  b) -> normCW $ CW (kindOf x) (CWAlgReal  (r a b))
                            (True, CWInteger  a, CWInteger  b) -> normCW $ CW (kindOf x) (CWInteger  (i a b))
                            (True, CWFloat    a, CWFloat    b) -> normCW $ CW (kindOf x) (CWFloat    (f a b))
                            (True, CWDouble   a, CWDouble   b) -> normCW $ CW (kindOf x) (CWDouble   (d a b))
                            (True, CWChar     a, CWChar     b) -> normCW $ CW (kindOf x) (CWChar     (c a b))
                            (True, CWString   a, CWString   b) -> normCW $ CW (kindOf x) (CWString   (s a b))
                            (True, CWUserSort a, CWUserSort b) -> normCW $ CW (kindOf x) (CWUserSort (u a b))
                            (True, CWList{},     CWList{})     -> error "Data.SBV.mapCW2: Unexpected call through mapCW2 with lists!"
                            _                                  -> error $ "SBV.mapCW2: impossible, incompatible args received: " ++ show (x, y)

-- | Show instance for 'CW'.
instance Show CW where
  show = showCW True

-- | Show instance for Generalized 'CW'
instance Show GeneralizedCW where
  show (ExtendedCW k) = showExtCW True k
  show (RegularCW  c) = showCW    True c

-- | Show a CW, with kind info if bool is True
showCW :: Bool -> CW -> String
showCW shk w | isBoolean w = show (cwToBool w) ++ (if shk then " :: Bool" else "")
showCW shk w               = liftCW show show show show show show snd shL w ++ kInfo
      where kInfo | shk  = " :: " ++ showBaseKind (kindOf w)
                  | True = ""
            shL xs = "[" ++ intercalate "," (map (showCW False . CW ke) xs) ++ "]"
              where ke = case kindOf w of
                           KList k -> k
                           kw      -> error $ "Data.SBV.showCW: Impossible happened, expected list, got: " ++ show kw

-- | A version of show for kinds that says Bool instead of SBool
showBaseKind :: Kind -> String
showBaseKind k@KUserSort {} = show k   -- Leave user-sorts untouched!
showBaseKind k = case show k of
                   ('S':sk) -> sk
                   s        -> s

-- | Create a constant word from an integral.
mkConstCW :: Integral a => Kind -> a -> CW
mkConstCW KBool        a = normCW $ CW KBool      (CWInteger (toInteger a))
mkConstCW k@KBounded{} a = normCW $ CW k          (CWInteger (toInteger a))
mkConstCW KUnbounded   a = normCW $ CW KUnbounded (CWInteger (toInteger a))
mkConstCW KReal        a = normCW $ CW KReal      (CWAlgReal (fromInteger (toInteger a)))
mkConstCW KFloat       a = normCW $ CW KFloat     (CWFloat   (fromInteger (toInteger a)))
mkConstCW KDouble      a = normCW $ CW KDouble    (CWDouble  (fromInteger (toInteger a)))
mkConstCW KChar        a = error $ "Unexpected call to mkConstCW (Char) with value: " ++ show (toInteger a)
mkConstCW KString      a = error $ "Unexpected call to mkConstCW (String) with value: " ++ show (toInteger a)
mkConstCW k@KList{}    a = error $ "Unexpected call to mkConstCW (" ++ show k ++ ") with value: " ++ show (toInteger a)
mkConstCW (KUserSort s _) a = error $ "Unexpected call to mkConstCW with uninterpreted kind: " ++ s ++ " with value: " ++ show (toInteger a)

-- | Generate a random constant value ('CWVal') of the correct kind.
randomCWVal :: Kind -> IO CWVal
randomCWVal k =
  case k of
    KBool         -> CWInteger <$> randomRIO (0, 1)
    KBounded s w  -> CWInteger <$> randomRIO (bounds s w)
    KUnbounded    -> CWInteger <$> randomIO
    KReal         -> CWAlgReal <$> randomIO
    KFloat        -> CWFloat   <$> randomIO
    KDouble       -> CWDouble  <$> randomIO
    -- TODO: KString/KChar currently only go for 0..255; include unicode?
    KString       -> do l <- randomRIO (0, 100)
                        CWString <$> replicateM l (chr <$> randomRIO (0, 255))
    KChar         -> CWChar . chr <$> randomRIO (0, 255)
    KUserSort s _ -> error $ "Unexpected call to randomCWVal with uninterpreted kind: " ++ s
    KList ek      -> do l <- randomRIO (0, 100)
                        CWList <$> replicateM l (randomCWVal ek)
  where
    bounds :: Bool -> Int -> (Integer, Integer)
    bounds False w = (0, 2^w - 1)
    bounds True  w = (-x, x-1) where x = 2^(w-1)

-- | Generate a random constant value ('CW') of the correct kind.
randomCW :: Kind -> IO CW
randomCW k = CW k <$> randomCWVal k
