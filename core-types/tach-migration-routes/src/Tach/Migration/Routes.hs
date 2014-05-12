{-# LANGUAGE QuasiQuotes, TemplateHaskell, TypeFamilies, RecordWildCards, OverloadedStrings, DeriveGeneric, GeneralizedNewtypeDeriving #-}
module Tach.Migration.Routes where

--General Haskell imports
import Data.Aeson
import qualified Data.Traversable as T
import Data.ByteString.Lazy
import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM.TVar
import Control.Monad
import Data.Text
import GHC.Generics
import Network.HTTP.Types
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.UTF8 as UTF
import qualified System.File.Tree as ST
import qualified Network.AWS.S3Simple as S3

-- Acid and file related
import Data.Acid
import Data.Acid.Advanced
import Data.Acid.Local

-- Containers
import qualified Data.Set as S
import qualified Data.Map as M

--External Tach imports
import Tach.Acid.Impulse.State
import Tach.Acid.Impulse.Cruds
import Tach.Impulse.Types.Impulse
import Tach.Impulse.Types.TimeValue
import Tach.Impulse.Types.TimeValueSeries
import Tach.Migration.Acidic.Types

-- Yesod and web related
import Yesod
import Yesod.Core
import Yesod.Core.Types

-- Used for serializing and deserializing keys for indexing
import qualified DirectedKeys as DK
import qualified DirectedKeys.Types as DK
import qualified Data.Serialize as S

--Directly related Tach imports
import Tach.Migration.Routes.Internal
import Tach.Migration.Instances


-- Data for dealing with incoming requests
newtype KeyPid = KeyPid { unKeyPid :: Int } deriving (Eq, Ord, Show,S.Serialize, Generic)
newtype KeySource = KeySource { unKeySource :: BS.ByteString } deriving (Eq, Ord, Show,S.Serialize, Generic)
newtype KeyDestination = KeyDestination { unKeyDestination :: BS.ByteString } deriving (Eq, Ord, Show, S.Serialize, Generic)
newtype KeyTime = KeyTime { unKeyTime :: Integer } deriving (Eq, Ord, Show, S.Serialize, Generic)

type IncomingKey = DK.DirectedKeyRaw KeyPid KeySource KeyDestination KeyTime


data MigrationRoutes = MigrationRoutes {
  migrationRoutesAcidPath :: FilePath
 ,migrationRoutesAcidMap :: TVar (M.Map IncomingKey (AcidState TVSimpleImpulseTypeStore)) --Possibly an acid map of acid states
 ,migrationRoutesTVKeySet :: S.Set TVKey                             --A set of TVKeys to handle which PIDs it is responsible for
}

mkYesod "MigrationRoutes" [parseRoutes|
/ HomeR GET
/migration/receive/time-series-data/#String ReceiveTimeSeriesR POST
/list/#String ListDataR GET
/kill KillNodeR GET
|]

instance Yesod MigrationRoutes

-- | Used for importing routes into other libraries
--   ONLY
migrationRoutesTransport :: IO MigrationRoutes
migrationRoutesTransport = do
  mMap <- newTVarIO M.empty  :: IO (TVar (M.Map IncomingKey (AcidState TVSimpleImpulseTypeStore)))
  return $ MigrationRoutes "" mMap (S.empty)

testServer = do
  let dKey = buildIncomingKey (KeyPid 299) (KeySource "www.aacs-us.com") (KeyDestination "http://cloud.aacs-us.com") (KeyTime 0)
      stateName = C.unpack . DK.parseFilename . DK.encodeKey $ dKey
  impulseState <- openLocalStateFrom stateName emptyStore
  mMap <- newTVarIO (impulseStateMap impulseState dKey)
  warp 3000 (MigrationRoutes "./teststate/" mMap (S.singleton . buildTestImpulseKey $ 299))
  where impulseStateMap state key = M.singleton key state

listTest = do
  impulseState <- openLocalStateFrom "teststate" emptyStore
  eRes <- query' impulseState (GetTVSimpleImpulseMany (buildTestImpulseKey 299) (ImpulseStart (-4879536533031178240)) (ImpulseEnd 5364650883968821760))
  closeAcidState impulseState
  case eRes of
    Left _ -> return S.empty
    Right res -> return res
  

buildIncomingKey :: KeyPid -> KeySource -> KeyDestination -> KeyTime -> IncomingKey
buildIncomingKey pid source dest time = DK.DKeyRaw pid source dest time

emptyStore :: TVSimpleImpulseTypeStore
emptyStore = buildTestImpulseTypeStore 299 0 0 [] [] 

getHomeR :: Handler Html
getHomeR = defaultLayout [whamlet|Simple API|]

-- | Gets a list of all data for the specific key
-- should probably be modified to include the start and end times
getListDataR :: String -> Handler Value
getListDataR stKey = do
  master <- getYesod
  migrationMap <- liftIO $ readTVarIO (migrationRoutesAcidMap master)
  let eDKey = DK.decodeKey (C.pack stKey) :: (Either String (DK.DirectedKeyRaw KeyPid KeySource KeyDestination KeyTime))
      eState = eDKey >>= (\dKey -> maybeToEither "Failed to lookup key" $ M.lookup dKey migrationMap)
      ePidkey = unKeyPid . DK.getSimpleKey <$> eDKey
  eRes <- T.sequence $ (\state pidKey ->
                          query' state (GetTVSimpleImpulseMany (ImpulseKey . toInteger $ pidKey) (ImpulseStart (-5879536533031178240)) (ImpulseEnd 5364650883968821760))) <$>
                            eState <*> ePidkey
  case eRes of
    Left s -> return . toJSON $ (show s) ++ (show ePidkey)
    Right (Left e) -> return . toJSON . show $ e
    Right (Right res) -> return . toJSON $ res


-- | Kills a node gracefully by closing the acid state
getKillNodeR :: Handler Value
getKillNodeR = do
  master <- getYesod
  migrationMap <- liftIO $ readTVarIO (migrationRoutesAcidMap master)
  let migrationElems = M.elems migrationMap
  let migrationKeys = M.keys migrationMap
  _ <- liftIO $ mapM createCheckpoint migrationElems
  _ <- liftIO $ mapM createArchive migrationElems
  _ <- liftIO $ mapM closeAcidState migrationElems
  directories <- liftIO $ mapM (ST.getDirectory . elemToPath) migrationKeys
  _ <- liftIO $ mapM ST.remove directories
  return . toJSON $ killing
  where killing :: Text
        killing = "Killing"
        elemToPath :: IncomingKey -> FilePath
        elemToPath key = UTF.toString $ BS.append (DK.encodeKey key) "/Archive" --Possibly find a way to make this a little safer?

--post body -> open state -> add post body to state -> check size (possibly start send)-> close state
--send action
postReceiveTimeSeriesR :: String -> Handler Value
postReceiveTimeSeriesR stKey = do
  master <- getYesod
  migrationMap <- liftIO $ readTVarIO (migrationRoutesAcidMap master)
  let eDKey = DK.decodeKey (C.pack stKey) :: (Either String (DK.DirectedKeyRaw KeyPid KeySource KeyDestination KeyTime))
      eState :: Either String (AcidState TVSimpleImpulseTypeStore)
      eState = eDKey >>= (\dKey -> maybeToEither "Failed to lookup key" $ M.lookup dKey migrationMap)
      ePidKey = unKeyPid . DK.getSimpleKey <$> eDKey
  eTsInfo <- resultToEither <$> parseJsonBody :: Handler (Either String [TVNoKey]) -- Get the post body
  rslt <- T.sequence $ (\state pidKey tvSet -> do
                      res <- update' state (InsertManyTVSimpleImpulse (ImpulseKey . toInteger $ pidKey) (S.fromList tvSet))
                      eSetSize <- query' state (GetTVSimpleImpulseSize (ImpulseKey . toInteger $ pidKey))
                      case eSetSize of 
                        Left _ -> return ()
                        Right setSize -> do
                          case () of _
                                      | setSize >= 1000 -> liftIO . void . forkIO $ testPrint
                                      | otherwise -> return ()
                      _ <- liftIO $ createCheckpoint state
                      return res) <$>
                      eState <*> 
                      ePidKey <*> 
                      eTsInfo
  _ <- liftIO $ Prelude.putStrLn $ "Pid Received:  " ++ (show ePidKey)
  return . toJSON . show $ rslt


uploadState state pidKey = do
  bounds <- query' state (GetTVSimpleImpulseTimeBounds key)
  case bounds of
    (Left _) -> return []
    (Right (lower,upper)) -> do
      eList <- query' state (GetTVSimpleImpulseMany key lower upper)
      case eList of
        Left _ -> return []
        Right list -> do
          return . uploadTVSimple $ list
  where
    key = ImpulseKey . toInteger $ pidKey


uploadTVSimple tvSet = undefined



maybeToEither :: String -> Maybe a -> Either String a
maybeToEither s Nothing = Left s
maybeToEither _ (Just o) = Right o

resultEither :: ToJSON a => (a -> c) -> (String -> c) -> Result a -> c
resultEither _ failure (Error s) = failure s
resultEither success _ (Success a) = success a

resultToEither :: Result a -> Either String a
resultToEither (Error s) = Left . show $ s
resultToEither (Success s) = Right s



testPrint :: IO ()
testPrint = do
  Prelude.putStrLn "RUNNING"
  testPrint

 --- Just used for testing below this point
buildTestImpulseRep :: [Integer] -> [Double] -> ImpulseRep (S.Set TVNoKey)
buildTestImpulseRep is ds = ImpulseRep . S.fromList $ Prelude.zipWith bldFcn is ds 
    where 
      bldFcn i d = TVNoKey i d



buildTestImpulseKey :: Integer -> TVKey
buildTestImpulseKey i = ImpulseKey i 

buildTestImpulseStart :: Integer -> TVSStart
buildTestImpulseStart i = ImpulseStart i 

buildTestImpulseEnd :: Integer -> TVSEnd
buildTestImpulseEnd i = ImpulseEnd i 


-- | This field is left blank because no period information has been calculated yet so it should stay blank
buildTestImpulsePeriod :: TVPeriod
buildTestImpulsePeriod = initialImpulsePeriod



buildTestImpulseSeries :: Integer -> Integer -> Integer -> [Integer] -> [Double] 
                       -> ImpulseSeries TVKey TVPeriod TVSStart TVSEnd (ImpulseRep (S.Set TVNoKey))
buildTestImpulseSeries key start end is ds = ImpulseSeries                                 
                                             (buildTestImpulseKey key )                    
                                             (buildTestImpulsePeriod)
                                             (buildTestImpulseStart start)
                                             (buildTestImpulseEnd end )
                                             (buildTestImpulseRep is ds)

buildTestImpulseTypeStore ::Integer -> Integer -> Integer -> [Integer] -> [Double] 
                          -> TVSimpleImpulseTypeStore 
buildTestImpulseTypeStore key start end is ds = TVSimpleImpulseTypeStore 
                                                (buildTestImpulseSeries key start end is ds)


