{-# LANGUAGE RankNTypes #-}

--------------------------------------------------------------------------------
-- | This part of the library provides you with utilities to create WebSockets
-- clients (in addition to servers).
module Network.WebSockets.Client
    ( ClientApp
    , runClient
    , runClientWith
    , runClientWithSocket
    , runClientWithStream
    ) where


--------------------------------------------------------------------------------
import qualified Blaze.ByteString.Builder as Builder
import Blaze.ByteString.Builder (Builder)
import Control.Exception (finally, throwIO)
import Data.IORef (newIORef)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.Socket as S
import qualified Data.Attoparsec.ByteString as A

import qualified Pipes as P
import Pipes ((>->))
import qualified Pipes.ByteString as P
import qualified Pipes.Parse as P
import qualified Pipes.Attoparsec as P
import qualified Pipes.Network.TCP as P
import Control.Concurrent.MVar

--------------------------------------------------------------------------------
import           Network.WebSockets.Connection
import           Network.WebSockets.Http
import           Network.WebSockets.Protocol
import           Network.WebSockets.Types


--------------------------------------------------------------------------------
-- | A client application interacting with a single server. Once this 'IO'
-- action finished, the underlying socket is closed automatically.
type ClientApp a = Connection -> IO a


--------------------------------------------------------------------------------
-- TODO: Maybe this should all be strings
runClient :: String       -- ^ Host
          -> Int          -- ^ Port
          -> String       -- ^ Path
          -> ClientApp a  -- ^ Client application
          -> IO (Either HandshakeException a)
runClient host port path ws =
    runClientWith host port path defaultConnectionOptions [] ws


--------------------------------------------------------------------------------
runClientWith :: String             -- ^ Host
              -> Int                -- ^ Port
              -> String             -- ^ Path
              -> ConnectionOptions  -- ^ Options
              -> Headers            -- ^ Custom headers to send
              -> ClientApp a        -- ^ Client application
              -> IO (Either HandshakeException a)
runClientWith host port path opts customHeaders app = do
    -- Create and connect socket
    let hints = S.defaultHints
                    {S.addrFamily = S.AF_INET, S.addrSocketType = S.Stream}
        fullHost = if port == 80 then host else (host ++ ":" ++ show port)
    addrInfos <- S.getAddrInfo (Just hints) (Just host) (Just $ show port)
    sock      <- S.socket S.AF_INET S.Stream S.defaultProtocol
    S.setSocketOption sock S.NoDelay 1

    -- Connect WebSocket and run client
    res <- finally
        (S.connect sock (S.addrAddress $ head addrInfos) >>
         runClientWithSocket sock fullHost path opts customHeaders app)
        (S.close sock)

    -- Clean up
    return res


--------------------------------------------------------------------------------
runClientWithStream :: (forall x. A.Parser x -> IO (Maybe x)) -- ^ Stream parse
                    -> (Builder -> IO ()) -- ^ Stream write
                    -> String -- ^ Host
                    -> String -- ^ Path
                    -> ConnectionOptions -- ^ Connection options
                    -> Headers -- ^ Custom headers to send
                    -> ClientApp a -- ^ Client application
                    -> IO (Either HandshakeException a)
runClientWithStream streamParse streamWrite host path opts customHeaders app = do
    -- Create the request and send it
    request    <- createRequest protocol bHost bPath False customHeaders
    streamWrite (encodeRequestHead request)
    mbResponse <- streamParse decodeResponseHead
    case mbResponse of
        Nothing -> return . Left . OtherHandshakeException $
            "Network.WebSockets.Client.runClientWithStream: no handshake response from server"
        Just response -> do
          -- Note that we pattern match to evaluate the result here
          case finishResponse protocol request response of
            Left e -> return (Left e)
            Right (Response _ _) -> do
              parse        <- decodeMessages protocol streamParse
              write        <- encodeMessages protocol ClientConnection streamWrite
              sentRef      <- newIORef False
              res <- app Connection
                           { connectionOptions   = opts
                           , connectionType      = ClientConnection
                           , connectionProtocol  = protocol
                           , connectionParse     = parse
                           , connectionWrite     = write
                           , connectionSentClose = sentRef
                           }
              return (Right res)
  where
    protocol = defaultProtocol  -- TODO
    bHost    = T.encodeUtf8 $ T.pack host
    bPath    = T.encodeUtf8 $ T.pack path


--------------------------------------------------------------------------------
runClientWithSocket :: S.Socket           -- ^ Socket
                    -> String             -- ^ Host
                    -> String             -- ^ Path
                    -> ConnectionOptions  -- ^ Options
                    -> Headers            -- ^ Custom headers to send
                    -> ClientApp a        -- ^ Client application
                    -> IO (Either HandshakeException a)
runClientWithSocket socket host path opts customHeaders app = do
  let producer = P.fromSocket socket 4096
  prodRef <- newMVar producer
  let consumer = P.toSocket socket
      parseStream p = do 
        res <- modifyMVar prodRef $ \pr -> do
           (res,pr') <- P.runStateT (P.parse p) pr
           return (pr',res)
        case res of
           Nothing -> return Nothing
           Just (Left e) -> throwIO e
           Just (Right x) -> return (Just x)
      writeStream b = P.runEffect (P.fromLazy (Builder.toLazyByteString b) >-> consumer)
      closeStream = do
        modifyMVar_ prodRef (\_ -> return (return ()))
        S.close socket
  runClientWithStream parseStream writeStream host path opts customHeaders app
    `finally` closeStream
