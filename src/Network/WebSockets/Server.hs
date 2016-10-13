--------------------------------------------------------------------------------
-- | This provides a simple stand-alone server for 'WebSockets' applications.
-- Note that in production you want to use a real webserver such as snap or
-- warp.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Network.WebSockets.Server
    ( ServerApp
    , runServer
    , runServerWith
    , makeListenSocket
    , makePendingConnection
    , makePendingConnectionFromStream
    ) where


--------------------------------------------------------------------------------
import Control.Concurrent (forkIOWithUnmask)
import Control.Exception  (allowInterrupt, bracket,
                           bracketOnError, finally, mask_,
                           throwIO)
import Control.Monad      (forever)
import Network.Socket     (Socket)
import qualified Network.Socket as S
import qualified Pipes as P
import Pipes ((>->))
import qualified Pipes.ByteString as P
import qualified Pipes.Parse as P
import qualified Pipes.Attoparsec as P
import qualified Pipes.Network.TCP as P
import qualified Data.Attoparsec.ByteString as A
import qualified Blaze.ByteString.Builder as Builder
import Blaze.ByteString.Builder (Builder)
import Control.Concurrent.MVar

--------------------------------------------------------------------------------
import Network.WebSockets.Connection
import Network.WebSockets.Http
import Network.WebSockets.Types

--------------------------------------------------------------------------------
-- | WebSockets application that can be ran by a server. Once this 'IO' action
-- finishes, the underlying socket is closed automatically.
type ServerApp = PendingConnection -> IO ()

--------------------------------------------------------------------------------
-- | Provides a simple server. This function blocks forever. Note that this
-- is merely provided for quick-and-dirty standalone applications, for real
-- applications, you should use a real server.
--
-- Glue for using this package with real servers is provided by:
--
-- * <https://hackage.haskell.org/package/wai-websockets>
--
-- * <https://hackage.haskell.org/package/websockets-snap>
runServer :: String     -- ^ Address to bind
          -> Int        -- ^ Port to listen on
          -> ServerApp  -- ^ Application
          -> IO ()      -- ^ Never returns
runServer host port app = runServerWith host port defaultConnectionOptions app

--------------------------------------------------------------------------------
-- | A version of 'runServer' which allows you to customize some options.
runServerWith :: String -> Int -> ConnectionOptions -> ServerApp -> IO ()
runServerWith host port opts app = S.withSocketsDo $
  bracket (makeListenSocket host port) S.close $ \sock ->
    mask_ . forever $ do
      allowInterrupt
      (conn, _) <- S.accept sock
      _ <- forkIOWithUnmask $ \unmask ->
        finally (unmask $ runApp conn opts app) (S.close conn)
      return ()

--------------------------------------------------------------------------------
-- | Create a standardized socket on which you can listen for incoming
-- connections. Should only be used for a quick and dirty solution! Should be
-- preceded by the call 'Network.Socket.withSocketsDo'.
makeListenSocket :: String -> Int -> IO Socket
makeListenSocket host port =
  bracketOnError (S.socket S.AF_INET S.Stream S.defaultProtocol) S.close $ \sock -> do
    _     <- S.setSocketOption sock S.ReuseAddr 1
    _     <- S.setSocketOption sock S.NoDelay   1
    host' <- S.inet_addr host
    S.bind sock (S.SockAddrInet (fromIntegral port) host')
    S.listen sock 5
    return sock

--------------------------------------------------------------------------------
runApp :: Socket
       -> ConnectionOptions
       -> ServerApp
       -> IO ()
runApp socket opts app =
    bracket (makePendingConnection socket opts) pendingStreamClose
      app

--------------------------------------------------------------------------------
-- | Turns a socket, connected to some client, into a 'PendingConnection'.
-- The 'PendingConnection' should be closed using 'pendingStreamClose' later.
-- The 'pendingStreamParse' may 'throwIO' a 'ParsingError'.
makePendingConnection :: Socket
                      -> ConnectionOptions
                      -> IO PendingConnection
makePendingConnection socket opts = do
  let producer = P.fromSocket socket 4096
  prodRef <- newMVar producer
  let consumer = P.toSocket socket
      parseStream p = do 
        res <- modifyMVar prodRef $ \pr -> do
          (res,pr') <- P.runStateT (P.parse p) pr
          return (pr', res)
        case res of
           Nothing -> return Nothing
           Just (Left e) -> throwIO e
           Just (Right x) -> return (Just x)
      writeStream b = P.runEffect (P.fromLazy (Builder.toLazyByteString b) >-> consumer)
      closeStream = do
        modifyMVar_ prodRef (\_ -> return (return ()))
        S.close socket
  makePendingConnectionFromStream parseStream writeStream closeStream opts

-- | More general version of 'makePendingConnection' for a stream
-- instead of a 'Socket'.
makePendingConnectionFromStream :: (forall a. A.Parser a -> IO (Maybe a)) -- ^ Read and parse the stream
                                -> (Builder -> IO ()) -- ^ Write the stream
                                -> IO () -- ^ Close the stream 
                                -> ConnectionOptions
                                -> IO PendingConnection
makePendingConnectionFromStream parseStream writeStream closeStream opts = do
  -- TODO: we probably want to send a 40x if the request is bad?
  mbRequest <- parseStream (decodeRequestHead False)
  case mbRequest of
    Nothing      -> throwIO ConnectionClosed
    Just request -> return PendingConnection
        { pendingOptions  = opts
        , pendingRequest  = request
        , pendingOnAccept = \_ -> return ()
        , pendingStreamParse = parseStream
        , pendingStreamWrite = writeStream
        , pendingStreamClose = closeStream
        }
