{-# LANGUAGE QuasiQuotes, TemplateHaskell, TypeFamilies, RecordWildCards, OverloadedStrings, DeriveGeneric, GeneralizedNewtypeDeriving #-}
module Tach.Periodic where

import Prelude hiding (foldl)
import Tach.Periodic.Internal
import System.Random
import Control.Applicative
import GHC.Generics
import Data.Maybe
import qualified Data.Sequence as S
import qualified Data.Foldable as F

newtype PeriodicData a = PeriodicData  { unPeriodicData :: S.Seq a } deriving (Eq, Show, Generic)
newtype APeriodicData a = APeriodicData { unAPeriodicData :: S.Seq a } deriving (Eq, Show, Generic)
data TVData a = TVPeriodic (PeriodicData a) | TVAPeriodic (APeriodicData a) deriving (Eq, Show, Generic)

data PeriodicFolding a = PeriodicFolding {
  firstPeriodic :: Int
 ,periodicCount :: Int
 ,timeValueData :: [TVData a]
}

tvDataToEither :: TVData a -> Either (APeriodicData a) (PeriodicData a)
tvDataToEither (TVPeriodic x) = Right x
tvDataToEither (TVAPeriodic x) = Left x

--testData :: IO [TVData Double]
--testData = do
--  rData <- genRandomData (0,10000) (10,100)
--  return $ combineAperiodic $ classifyPeriodic 10 10 rData

testList :: [Double]
testList = aperiodicTimeData 515.0 1000.0 100

seqToList :: S.Seq a -> [a]
seqToList = (F.foldr' (\item list -> item:list) [])

combineAperiodic :: S.Seq (TVData a) -> S.Seq (TVData a)
combineAperiodic = F.foldl' combineAperiodicFold S.empty

classifyData :: (Num a, Ord a) => a -> a -> Int -> (b -> a) -> [b] -> ([TVData b])
classifyData  period delta minPeriodicSize toNumFunc list = seqToList . combineAperiodic . (removePeriodicBelow minPeriodicSize) $ classifyPeriodic period delta toNumFunc (S.fromList list)

removePeriodicBelow :: Int -> S.Seq (TVData a) -> S.Seq (TVData a)
removePeriodicBelow minSize list = (setAperiodicBelow minSize) <$> list

setAperiodicBelow :: Int -> (TVData a) -> (TVData a)
setAperiodicBelow minSize val@(TVPeriodic (PeriodicData periodic)) =
  if ((S.length periodic) < minSize)
    then TVAPeriodic $ APeriodicData periodic
    else val
setAperiodicBelow _ b = b

-- Appends the TVData to the last element of the TVData list if both are aperiodic
combineAperiodicFold :: S.Seq (TVData a) -> TVData a -> S.Seq (TVData a)
combineAperiodicFold list item = 
  let end = lastMaySeq list
  in case end of
    Nothing -> S.singleton item
    (Just (TVAPeriodic (APeriodicData periodicList))) ->
      case item of
        (TVAPeriodic (APeriodicData aSeq)) ->
          (initSeq list) S.|> (TVAPeriodic $ APeriodicData (periodicList S.>< aSeq))
        _ -> list S.|> item
    (Just (TVPeriodic (PeriodicData _))) -> list  S.|> item

classifyPeriodic :: (Num a, Ord a) => a -> a -> (b -> a) -> S.Seq b -> S.Seq (TVData b)
classifyPeriodic period delta toNumFunc list = F.foldl' (takePeriodic period delta toNumFunc) S.empty list

-- | The function that folds over a list and looks for any matches in a period
takePeriodic :: (Num a, Ord a) => a -> a -> (b -> a) -> S.Seq (TVData b) -> b ->  S.Seq (TVData b)
takePeriodic period delta toNumFunc old current = 
  let maxPeriod = period + delta
      minPeriod = period - delta
      mLast = lastMaySeq old
  in case mLast of
    Nothing ->
      S.singleton $ TVAPeriodic $ APeriodicData (S.singleton current)
    (Just (TVPeriodic (PeriodicData periodData))) ->
      let firstVal = lastSeq periodData
          difference = abs $ (toNumFunc current) - (toNumFunc firstVal)
      in if ((difference <= maxPeriod) && (difference >= minPeriod))
        then ((initSeq old) S.|> (TVPeriodic . PeriodicData $  periodData S.|> current))
        else ((old) S.|> (TVAPeriodic $ APeriodicData (S.singleton current)))
    (Just (TVAPeriodic (APeriodicData aperiodicData))) -> 
      let lastVal = lastSeq aperiodicData
          difference = abs $ (toNumFunc current) - (toNumFunc lastVal)
      in if ((difference <= maxPeriod) && (difference >= minPeriod))
        then ((initSeq old) S.|> (TVPeriodic . PeriodicData $ aperiodicData S.|> current))
        else (old S.|> (TVAPeriodic $ APeriodicData (S.singleton current)))

headSeq :: S.Seq a -> a
headSeq = fromJust . headMaySeq

headMaySeq :: S.Seq a -> Maybe a
headMaySeq aSeq = 
  if (len >= 1)
    then
      Just $ S.index aSeq (len - 1)
    else
      Nothing
  where len = S.length aSeq

initSeq :: S.Seq a -> S.Seq a
initSeq aSeq = 
  if (len >= 1)
    then
      if (len == 1)
        then
          S.empty
        else
          S.take (len - 1) aSeq
    else
      S.empty
  where len = S.length aSeq


lastSeq :: S.Seq a -> a
lastSeq = fromJust . lastMaySeq

lastMaySeq :: S.Seq a -> Maybe a
lastMaySeq aSeq = 
  if (len >= 1)
    then
      Just $ S.index aSeq (len - 1)
    else
      Nothing
  where len = S.length aSeq

periodStart :: Double -> Int -> Int -> [Int]
periodStart start count period = take count [(round start) + (x*period) | x <- [0..]]


--classifiy :: [(Double, Double)] -> V.Vector 
--classify xs = foldl' addPeriodic []

--addPeriodic :: 

linSpace :: Double -> Double -> Int -> [Double]
linSpace start end n
  | n-1 <= 0 = []
  | otherwise = 
      map (\x -> (x * mult) + start) (take (n - 1) [0..])
      where mult = (end - start) / (fromIntegral l)
            l = n-1 :: Int

aperiodicTimeData :: Double -> Double -> Int -> [Double]
aperiodicTimeData start end n = [x+(sin x) | x <- (linSpace start end n)]


randomChunks :: Double -> Double -> Double -> Double -> IO [(Double,Double)]
randomChunks start end minStep maxStep
  | (end - start) < minStep = return [(start,end+minStep)]
  | otherwise = do
    step <- randomRIO (minStep,maxStep)
    let newEnd = start+step
    case newEnd > end of
      True -> return [(start,end)]
      False -> do
        xs <- randomChunks (newEnd + 16) end minStep maxStep
        return $ (start,newEnd):xs

getRandomList :: Int -> (Int,Int) -> IO [Int]
getRandomList size range = mapM (\_ -> randomRIO range) [1..size]

randomData :: (Double,Double) -> IO (TVData Double)
randomData (start,end) = do
  randomChoice <- randomRIO (0,10) :: IO Int
  case randomChoice of
    _
      | randomChoice <= 5 -> do --Get a period with 15 second intervals
          let xs = linSpace start end (round ((end - start)/15))
          return . TVPeriodic . PeriodicData . S.fromList $ xs
      | otherwise -> do
        randomCount <- randomRIO ((end - start)/15, (end - start)/200)
        let xs = aperiodicTimeData start end (round randomCount)
        return . TVAPeriodic . APeriodicData . S.fromList $ xs

genRandomData :: (Double,Double) -> (Double, Double) -> IO [(TVData Double)]
genRandomData (start,end) (minStep,maxStep) = do
  chunks <- randomChunks start end minStep maxStep
  chunkedData <- mapM randomData chunks
  return . removeEmptyRandoms $ chunkedData

removeTVData :: (Num a, Ord a) => [TVData a] -> [a]
removeTVData list = F.foldl' removeTVDataFold [] list

removeTVDataFold :: (Num a, Ord a) => [a] -> TVData a -> [a]
removeTVDataFold list item =list ++ (seqToList . unTVData $ item)


unTVData :: (Num a, Ord a) => TVData a -> S.Seq a
unTVData (TVPeriodic (PeriodicData c)) = c
unTVData (TVAPeriodic (APeriodicData b)) = b

removeEmptyRandoms :: [TVData Double] -> [TVData Double]
removeEmptyRandoms xs = F.foldl' remEmpty [] xs


remEmpty :: [TVData Double] -> TVData Double -> [TVData Double]
remEmpty ys xs@(TVPeriodic (PeriodicData x)) =
  if (S.null x) then ys else (ys ++ [xs])
remEmpty ys xs@(TVAPeriodic (APeriodicData x)) =
  if (S.null x) then ys else (ys ++ [xs])