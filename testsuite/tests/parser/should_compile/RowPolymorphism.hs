{-# LANGUAGE RowPolymorphism #-}

module RowPolymorphism where

-- type ClosedRow = (foo :: Integer, bar :: String |)

type SingleRow = (foo :: Integer |)
type SingleRowVar a = (foo :: a |)
