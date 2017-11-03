{-|
@since 2.7.2

Module: module Database.Persist.Sql.Raw.QQ
Description: QuasiQuoters for performing raw sql queries

This module exports convenient QuasiQuoters to perform raw SQL queries.
All QuasiQuoters follow them same pattern and are analogous to the similar named
functions exported from 'Database.Persist.Sql.Raw'. Neither the quoted
function's behaviour, nor it's return value is altered during the translation
and all documentation provided with it holds.

The QuasiQuoters in this module perform a simple substitution on the query text,
that allows value substitutions, table name substitutions as well as column name
substitutions.

Here is a small example:

Given the following simple model:

@
Category
  rgt Int
  lft Int
@

We can now execute this raw query:

@
let lft = 10 :: Int
    rgt = 20 :: Int
    width = rgt - lft
 in [sqlQQ|
      DELETE FROM ^{Category} WHERE @{CategoryLft} BETWEEN #{lft} AND #{rgt};
      UPDATE category SET @{CategoryRgt} = @{CategoryRgt} - #{width} WHERE @{CategoryRgt} > #{rgt};
      UPDATE category SET @{CategoryLft} = @{CategoryLft} - #{width} WHERE @{CategoryLft} > #{rgt};
    |]
@

@^{TableName}@ looks up the table's name and escapes it, @\@{ColumnName}@ looks
up the column's name and properly escapes it and @#{value}@ inserts the value
via the usual parameter substitution mechanism.
-}

{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fno-warn-unused-imports #-}

module Database.Persist.Sql.Raw.QQ (
      -- * Sql QuasiQuoters
      queryQQ
    , queryResQQ
    , sqlQQ
    , executeQQ
    , executeCountQQ
    ) where

import Prelude hiding (fail)
import Control.Arrow (first, second)
import Control.Monad.Reader (ask)
import Control.Monad.Fail (fail)
import Data.Text (pack, unpack)
import Data.Maybe (fromMaybe, Maybe(..))
import Data.Monoid (mempty, (<>))
import qualified Language.Haskell.TH as TH
import Language.Haskell.TH.Quote
import Language.Haskell.Meta.Parse

import Database.Persist.Class (toPersistValue)
import Database.Persist.Sql.Raw (rawSql, rawQuery, rawQueryRes, rawExecute, rawExecuteCount)
import Database.Persist.Sql.Types (connEscapeName)

data Token
  = Literal String
  | Value String
  | TableName String
  | ColumnName String
  deriving Show

parseHaskell :: (String -> Token) -> String -> String -> [Token]
parseHaskell cons = go
    where
    go a []          = [Literal (reverse a)]
    go a ('\\':x:xs) = go (x:a) xs
    go a ['\\']      = go ('\\':a) []
    go a ('}':xs)    = cons (reverse a) : parseStr [] xs
    go a (x:xs)      = go (x:a) xs

parseStr :: String -> String -> [Token]
parseStr a []           = [Literal (reverse a)]
parseStr a ('\\':x:xs)  = parseStr (x:a) xs
parseStr a ['\\']       = parseStr ('\\':a) []
parseStr a ('#':'{':xs) = Literal (reverse a) : parseHaskell Value      [] xs
parseStr a ('^':'{':xs) = Literal (reverse a) : parseHaskell TableName  [] xs
parseStr a ('@':'{':xs) = Literal (reverse a) : parseHaskell ColumnName [] xs
parseStr a (x:xs)       = parseStr (x:a) xs

makeExpr :: TH.ExpQ -> [Token] -> TH.ExpQ
makeExpr fun toks = do
    TH.infixE
        (Just [| uncurry $(fun) |])
        ([| (=<<) |])
        (Just $ go toks)

    where
    go :: [Token] -> TH.ExpQ
    go [] = [| pure (mempty, mempty) |]
    go (Literal a:xs) =
        TH.appE
            [| fmap $ first (pack a <>) |]
            (go xs)
    go (Value a:xs) =
        TH.appE
            [| fmap $ first ("?" <>) . second (toPersistValue $(reifyExp a) :) |]
            (go xs)
    go (ColumnName a:xs) = do
        colN <- TH.newName "field"
        TH.infixE
            (Just [| getFieldName $(reifyExp a) |])
            [| (>>=) |]
            (Just $ TH.lamE [ TH.varP colN ] $
                TH.appE
                    [| fmap $ first ($(TH.varE colN) <>) |]
                    (go xs))
    go (TableName a:xs) = do
        typeN <- TH.lookupTypeName a >>= \case
                Just t  -> pure t
                Nothing -> fail $ "Type not in scope: " ++ show a
        tableN <- TH.newName "table"
        TH.infixE
            (Just $
                TH.appE
                    [| getTableName |]
                    (TH.sigE
                        [| error "record" |] $
                        (TH.conT typeN)))
            [| (>>=) |]
            (Just $ TH.lamE [ TH.varP tableN ] $
                TH.appE
                    [| fmap $ first ($(TH.varE tableN) <>) |]
                    (go xs))

reifyExp :: String -> TH.Q TH.Exp
reifyExp s =
    case parseExp s of
        Left e -> TH.reportError e >> [| mempty |]
        Right v -> return v

makeQQ :: TH.Q TH.Exp -> QuasiQuoter
makeQQ x = QuasiQuoter
    (makeExpr x . parseStr [])
    (error "Cannot use qc as a pattern")
    (error "Cannot use qc as a type")
    (error "Cannot use qc as a dec")

-- | Analoguous to 'Database.Persist.Sql.Raw.rawSql'
-- @since 2.7.2
sqlQQ :: QuasiQuoter
sqlQQ = makeQQ [| rawSql |]

-- | Analoguous to 'Database.Persist.Sql.Raw.rawExecute'
-- @since 2.7.2
executeQQ :: QuasiQuoter
executeQQ = makeQQ [| rawExecute |]

-- | Analoguous to 'Database.Persist.Sql.Raw.rawExecuteCount'
-- @since 2.7.2
executeCountQQ :: QuasiQuoter
executeCountQQ = makeQQ [| rawExecuteCount |]

-- | Analoguous to 'Database.Persist.Sql.Raw.rawQuery'
-- @since 2.7.2
queryQQ :: QuasiQuoter
queryQQ = makeQQ [| rawQuery |]

-- | Analoguous to 'Database.Persist.Sql.Raw.rawQueryRes'
-- @since 2.7.2
queryResQQ :: QuasiQuoter
queryResQQ = makeQQ [| rawQueryRes |]
