{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, KindSignatures, GADTs #-}
module Web.KansasComet
    ( connect
    , extract
    , event
    , kCometPlugin
    , register
    , registerEvents
    , send
    , waitForEvent
    , query
    , queryGlobal
    , Document
    , Options(..)
    , Scope
    , Template(..)
    , (.=)
    , field
    , (<&>)
    , abort
    , Abort
    , docUniq
    , docUniqs
    ) where

import Web.Scotty (ScottyM, text, post, capture, param, header, get, ActionM, jsonData)
import Data.Aeson hiding ((.=))
import Data.Aeson.Types hiding ((.=))
import Control.Monad
import Control.Concurrent.STM as STM
import Control.Concurrent.MVar as STM
import Control.Monad.IO.Class
import Paths_kansas_comet
import qualified Data.Map as Map
import Control.Concurrent
import Control.Applicative
import Data.Default
import Data.List
import Data.Semigroup
import Data.Maybe ( fromJust )
import qualified Data.HashMap.Strict as HashMap

import qualified Data.Text.Lazy as LT
import qualified Data.Text      as T

-- | connect "/foobar" (...) gives

-- >  POST http://.../foobar/                       <- bootstrap the interaction
-- >  GET  http://.../foobar/act/<id#>/<act#>       <- get a specific action
-- >  POST http://.../foobar/reply/<id#>/<reply#>   <- send a reply as a JSON object

connect :: Options             -- ^ URL path prefix for this page
        -> (Document -> IO ()) -- ^ called for access of the page
        -> ScottyM ()
connect opt callback = do
   when (verbose opt >= 1) $ liftIO $ putStrLn $ "kansas-comet connect with prefix=" ++ show (prefix opt)

   -- A unique number generator, or ephemeral generator.
   -- This is the (open) secret between the client and server.
   -- (Why are we using an MVar vs a TMVar? No specific reason here)
   uniqVar <- liftIO $ newMVar 0
   let getUniq :: IO Int
       getUniq = do
              u <- takeMVar uniqVar
              putMVar uniqVar (u + 1)
              return u

   contextDB <- liftIO $ atomically $ newTVar $ (Map.empty :: Map.Map Int Document)
   let newContext :: IO Int
       newContext = do
            uq <- getUniq
            picture <- atomically $ newEmptyTMVar
            callbacks <- atomically $ newTVar $ Map.empty
            uqVar <- atomically $ newTVar 0
            let cxt = Document picture callbacks uq uqVar
            liftIO $ atomically $ do
                    db <- readTVar contextDB
                    -- assumes the getUniq is actually unique
                    writeTVar contextDB $ Map.insert uq cxt db
            -- Here is where we actually spawn the user code
            _ <- forkIO $ callback cxt
            return uq

   -- POST starts things off.
   post (capture $ prefix opt ++ "/") $ do
--            liftIO $ print "got root"
            uq  <- liftIO $ newContext
            text (LT.pack $ "$.kc.session(" ++ show uq ++ ");")

   -- GET the updates to the documents (should this be an (empty) POST?)

--   liftIO $ print $ prefix opt ++ "/act/:id/:act"
   get (capture $ prefix opt ++ "/act/:id/:act") $ do
            header "Cache-Control" "max-age=0, no-cache, private, no-store, must-revalidate"
            -- do something and return a new list of commands to the client
            num <- param "id"

            when (verbose opt >= 2) $ liftIO $ putStrLn $
                "Kansas Comet: get .../act/" ++ show num
--            liftIO $ print (num :: Int)

            let tryPushAction :: TMVar T.Text -> Int -> ActionM ()
                tryPushAction var n = do
                    -- The PUSH archtecture means that we wait upto 3 seconds if there
                    -- is not javascript to push yet. This stops a busy-waiting
                    -- (or technically restricts it to once every 3 second busy)
                    ping <- liftIO $ registerDelay (3 * 1000 * 1000)
                    res <- liftIO $ atomically $ do
                            b <- readTVar ping
                            if b then return Nothing else do
                                 liftM Just (takeTMVar var)


                    when (verbose opt >= 2) $ liftIO $ putStrLn $
                                "Kansas Comet (sending to " ++ show n ++ "):\n" ++ show res

                    case res of
                     Just js -> do
--                            liftIO $ putStrLn $ show js
                            text $ LT.pack $ T.unpack js
                     Nothing  ->
                            -- give the browser something to do (approx every 3 seconds)
                            text (LT.pack "")

            db <- liftIO $ atomically $ readTVar contextDB
            case Map.lookup num db of
               Nothing  -> text (LT.pack $ "alert('Can not find act #" ++ show num ++ "');")
               Just doc -> tryPushAction (sending doc) num


   post (capture $ prefix opt ++ "/reply/:id/:uq") $ do
           header "Cache-Control" "max-age=0, no-cache, private, no-store, must-revalidate"
           num <- param "id"
           uq :: Int <- param "uq"
           --liftIO $ print (num :: Int, event :: String)

           when (verbose opt >= 2) $ liftIO $ putStrLn $
                "Kansas Comet: post .../reply/" ++ show num ++ "/" ++ show uq

           wrappedVal :: Value <- jsonData
           -- Unwrap the data wrapped, because 'jsonData' only supports
           -- objects or arrays, but not primitive values like numbers
           -- or booleans.
           let val = fromJust $ let (Object m) = wrappedVal
                                in HashMap.lookup (T.pack "data") m
           --liftIO $ print (val :: Value)
           db <- liftIO $ atomically $ readTVar contextDB
           case Map.lookup num db of
               Nothing  -> do
                   --liftIO $ print ("ignoring reply",uq,val)
                   text (LT.pack $ "alert('Ignore reply for session #" ++ show num ++ "');")
               Just doc -> do
                   liftIO $ do
                         atomically $ do
                           m <- readTVar (listening doc)
                           writeTVar (listening doc) $ Map.insert uq val m
                   text $ LT.pack ""

   return ()

-- 'kCometPlugin' provide access to the Kansas Comet jQuery plugin. The argument
-- is the path to the collection that holds the static javascript files.
kCometPlugin :: IO String
kCometPlugin = do
        dataDir <- getDataDir
        return $ dataDir ++ "/static/js/kansas-comet.js"

-- 'send' sends a javascript fragement to a document.
-- The string argument will be evaluated before sending (in case there is an error,
-- or some costly evaluation needs done first).
-- 'send' suspends the thread if the last javascript has not been *dispatched*
-- the the browser.
send :: Document -> String -> IO ()
send doc js = atomically $ putTMVar (sending doc) $! T.pack js

-- The String argument returns an object, which is what part of the event get sent to Haskell.
register :: Document -> Scope -> EventName -> String -> IO ()
register doc scope eventName eventBuilder =
        send doc $ concat
                        [ "$.kc.register(" ++ show scope ++ "," ++ show eventName ++ ",function(widget,event,aux) {"
                        , eventBuilder
                        , "});"
                        ]

waitForEvent :: Document -> Scope -> Template event -> IO (Maybe event)
waitForEvent doc scope tmpl = do
        uq <- docUniq doc -- Is random generation really neeed? later, have this random generated
        let eventNames = map fst $ extract tmpl
        send doc $ concat
                [ "$.kc.waitFor(" ++ show scope ++ "," ++ show eventNames ++ ",function(e) { $.kc.reply(" ++ show uq ++ ",e);});" ]
        res <- getReply doc uq
        case parse (parserFromJSON tmpl) res of
           Success evt -> return $ Just evt
           _           -> return $ Nothing     -- something went wrong

-- internal function, waits for a numbered reply
getReply :: Document -> Int -> IO Value
getReply doc num = do
        atomically $ do
           db <- readTVar (listening doc)
           case Map.lookup num db of
              Nothing -> retry
              Just r -> do
                      writeTVar (listening doc) $ Map.delete num db
                      return r

-- TODO: make thread safe
-- The test ends with a return for the value you want to see.
-- | @query doc js@ executes the given @js@ Java Script
--   in the scope of a local function
--   and replies with the return value of that function.
query :: Document -> String -> IO Value
query doc qText = do
        uq <- docUniq doc
        send doc $ concat
                [ "$.kc.reply(" ++ show uq ++ ",function(){"
                , qText
                , "}());"
                ]
        getReply doc uq

-- TODO: make thread safe
-- The test ends with a return for the value you want to see.
-- | @queryGlobal doc (js, retVal)@ executes the given @js@ Java Script
--   in the global scope of the document
--   (not boxing it into a local function scope)
--   and replies with the @retVal@ return value.
queryGlobal :: Document -> (String, String) -> IO Value
queryGlobal doc (js, retVal) = do
        uq <- docUniq doc
        -- should be uniq or is the document id sufficient?
        send doc $ concat
                [ js, ";"
                , "$.kc.reply(", show uq, ",(", retVal, "));"
                ]
        getReply doc uq

type EventName = String

type Scope = String

data Document = Document
        { sending   :: TMVar T.Text             -- ^ Code to be sent to the browser
                                                -- This is a TMVar to stop the generation
                                                -- getting ahead of the rendering engine
        , listening :: TVar (Map.Map Int Value) -- ^ This is numbered replies.
        , secret    :: Int                      -- ^ the (session) number of this document
        , uVar      :: TVar Int                 -- ^ Uniq number supply
        }

-- | Generate one unique integer from the document.
docUniq :: Document -> IO Int
docUniq = docUniqs 1

-- | Generate n unique integers from the document.
docUniqs :: Int -> Document -> IO Int
docUniqs n doc = atomically $ do
        u <- readTVar (uVar doc)
        writeTVar (uVar doc) (u + n)
        return u

data Options = Options
        { prefix  :: String
        , verbose :: Int                -- 0 == none, 1 == inits, 2 == cmds done, 3 == complete log
        }

instance Default Options where
  def = Options
        { prefix = ""                   -- default to root, this assumes single page, etc.
        , verbose = 1
        }


-- | Structure of a Record for showing
type Record = [(String,String)]

-- | Builds a statement that returns a record of named fields.
record :: Record -> String
record xs = "return { " ++ concat (intersperse " , " [ tag ++ " : " ++ expr | (tag,expr) <- xs ]) ++ " };"

{-
res <- query doc (Text.pack "return { wrapped : $('#fib-in').attr('value') };")
-}

data Wrapped a = Wrapped a
        deriving Show

instance FromJSON a => FromJSON (Wrapped a) where
   parseJSON (Object v) = Wrapped    <$>
                          (v .: "wrapped")
   parseJSON _          = mzero

(.=) :: String -> String -> Field a
(.=) = Field

data Field a = Field String String

-- For fields of things we never need to register for (system-level in events, like abort).
field :: String -> Field a
field nm = Field nm "null"

--field :: String -> String -> Field a
--field = Field

event :: String -> a -> Template a
event = Pure

(<&>) :: (FromJSON a) => Template (a -> b) -> Field a -> Template b
(<&>) = App

-- TODO: Schema
data Template :: * -> * where
        App :: FromJSON a => Template (a -> b) -> Field a -> Template b
        Pure :: String -> a                               -> Template a
        Append :: Template a -> Template a                  -> Template a

instance Semigroup (Template a) where
        (<>) = Append


instance Functor Template where
        fmap f (App t fld)    = App (fmap (fmap f) t) fld
        fmap f (Pure nm a)    = Pure nm (f a)
        fmap f (Append t1 t2) = Append (fmap f t1) (fmap f t2)


infixl 1 <&>

parserFromJSON :: Template a -> Value -> Parser a
parserFromJSON (Pure nm a) (Object v) = do
        nm' <- (v .: T.pack "eventname")        -- house rule; *always* has an eventname
        if nm == nm' then pure a
                     else mzero
parserFromJSON (p `App` (Field nm _)) o@(Object v) = parserFromJSON p o <*> (v .: T.pack nm)
parserFromJSON (Append t1 t2)      o            = parserFromJSON t1 o <|> parserFromJSON t2 o
parserFromJSON _                   _            = mzero

registerEvents :: Document -> Scope -> Template event -> IO ()
registerEvents doc scope tmpls
        = sequence_ [ register doc scope nm (record fields)
                    | (nm,fields) <- extract tmpls
                    ]


extract :: Template a -> [(String, [(String, String)])]
extract tmpl = go tmpl []
  where
          go :: Template a -> [(String,String)] -> [(String, [(String, String)])]
          go (Pure nm _) xs            = [(nm,xs)]
          go (t `App` (Field nm expr)) xs = go t ((nm,expr) : xs)
          go (Append t1 t2)         xs = go t1 xs ++ go t2 xs

abort :: Template Abort
abort = event "abort" Abort
            <&> field "whyabort"
            <&> field "count"
            <&> field "message"
            <&> field "type"

data Abort = Abort String Int Value Value
        deriving (Show)
