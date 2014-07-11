{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

import System.IO
import System.Directory
import Network.HTTP.Conduit
import Control.Lens
import Control.Monad
import Control.Monad.Trans.Resource
import Control.Concurrent hiding (yield)
import Control.Exception.Lifted
import Control.Monad.IO.Class
import Control.Monad.Logger
import Control.Applicative
import Data.Default.Class
import Web.Twitter.Conduit hiding (map)
import Web.Authenticate.OAuth
import qualified Data.ByteString.Char8 as S
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TL
import Data.Function
import Data.Conduit
import Text.Feed.Import
import Text.Feed.Types
import Text.RSS.Syntax
import Data.Time
import Data.List
import qualified Data.Aeson as JSON
import qualified Data.Aeson.Lens as JSON
import Data.Maybe
import System.Locale

createTwInfo :: FilePath -> IO TWInfo
createTwInfo cfg = do
    ck:cs:ak:as:_ <- S.lines <$> S.readFile cfg
    let tokens = twitterOAuth
            { oauthConsumerKey    = key ck
            , oauthConsumerSecret = key cs
            }
        credential = Credential 
            [ ("oauth_token",        key ak)
            , ("oauth_token_secret", key as)
            ]

    return $ def
        { twToken = def { twOAuth = tokens, twCredential = credential }
        , twProxy = Nothing
        }
    where
      key = S.takeWhile (`notElem` "\n\r")

updateFromChan :: (MonadResource m, MonadLogger m, MonadIO m, MonadBaseControl IO m)
               => Int -> Chan RSSItem -> TW m b
updateFromChan len chan = loop `catch` (\(e :: SomeException) -> do
    liftIO $ print e
    liftIO $ threadDelay (300 * 10^(6::Int))
    updateFromChan len chan
    )
  where
    loop = do
        t <- liftIO $ readChan chan
        _ <- maybe (return ()) (void . call . update) (formatTwitter len t)
        loop

sinkChan :: MonadIO m => Chan i -> Consumer i m ()
sinkChan chan = awaitForever $ liftIO . writeChan chan

sourceFeed :: (MonadBaseControl IO m, MonadIO m)
           => Request -> Manager -> MVar UTCTime -> Producer m RSSItem
sourceFeed req mgr mvar = loop `catchC` (\(e::SomeException) -> do
    liftIO $ print e
    liftIO $ threadDelay (300 * 10^(6::Int))
    sourceFeed req mgr mvar)
  where
    loop = do
        feed <- parseFeedString . TL.unpack . TL.decodeUtf8 . responseBody <$> httpLbs req mgr
        case feed of
            Just (RSSFeed RSS{rssChannel = RSSChannel{rssItems = items}}) -> do
                lastTime <- liftIO $ readMVar mvar
                let items' = mapMaybe (\i -> do
                        pubd <- rssItemPubDate i
                        time <- parseTime defaultTimeLocale "%a, %e %b %Y %T %Z" pubd
                        return (time :: UTCTime, i)
                        ) items
                let new = filter ((> lastTime) . fst) items'
                mapM_ (yield . snd) $ sortBy (compare `on` fst) new
                liftIO $ putStrLn $ "yield " ++ show (length new) ++ " packages."
                liftIO $ hFlush stdout
                liftIO $ modifyMVar_ mvar (\_ -> do
                    let newTime = maximum $ map fst items'
                    writeFile "time.txt" $ show newTime
                    return newTime
                    )
                liftIO $ threadDelay (600 * 10^(6::Int))
            _ -> return ()
        loop

formatTwitter :: Int -> RSSItem -> Maybe T.Text
formatTwitter len f = do
    title  <- T.pack <$> rssItemTitle f
    author <- T.pack . takeWhile (/= ',') . drop 12 <$> rssItemDescription f
    desc   <- snd . T.breakOnEnd "</i><p>" . T.pack <$> rssItemDescription f
    url    <- T.pack <$> rssItemLink f
    let body = T.concat [title, ", ", author, ", ", desc]
    return $ T.take (140 - len) (body `T.snoc` ' ') `T.append` url

main :: IO ()
main = do 
    chan   <- liftIO newChan
    twInfo <- createTwInfo  "tokens.txt"
    req    <- parseUrl      "https://hackage.haskell.org/packages/recent.rss"
    ct     <- doesFileExist "time.txt" >>= \case
        True  -> read  <$> readFile "time.txt"
        False -> return $  read "1990-01-01 00:00:00.000000 UTC"
    mvar   <- newMVar ct
    _      <- forkIO $ withManager $ \mgr ->
        sourceFeed req mgr mvar $$ sinkChan chan
    runNoLoggingT . runTW twInfo $ do
        conf <- call $ APIRequestGet "https://api.twitter.com/1.1/help/configuration.json" []
        let len = (conf :: JSON.Value) ^? JSON.key "short_url_length_https" . JSON._Integer
        updateFromChan (maybe 25 fromIntegral len) chan
