{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE DataKinds #-}

-- FIXME: If you hit e when focused on an empty list, and then hit enter, will crash

module Main where

import Control.Monad (void)

import Lens.Micro
import GHC.Generics
import Data.Generics.Product

import qualified Graphics.Vty as V
import qualified Brick.Main as M
import qualified Brick.Types as T
import qualified Brick.Widgets.Border as B
import qualified Brick.Widgets.List as L
import qualified Brick.Widgets.Center as C
import qualified Brick.Widgets.Edit as E
import qualified Brick.AttrMap as A
import qualified Data.Vector as Vec
import Brick.Types
  ( Widget
  )
import Brick.Widgets.Core
  ( str
  , vLimit
  , hLimit
  , hBox
  , vBox
  , fill
  )
import Brick.Util (on)

import qualified NonEmptyZipper as NEZ
import qualified Zipper as Z
import qualified Data.Text.Zipper as TZ

newtype ID = ID Int
    deriving (Eq, Enum)

data Task = Task {
    taskID :: ID,
    taskName :: String,
    taskOnDay :: Bool
} deriving (Generic)

data TodoList = TL String [Task]
              | MyDay

data Focus = Lists
           | Tasks
           deriving (Show, Eq)

data CurrentState = CS {
    csLists :: (NEZ.Zipper TodoList),
    csFocus :: Focus,
    csTasks :: (Maybe (Z.Zipper Task)),
    csEditor :: (Maybe (E.Editor String String))
} deriving (Generic)

setEditorTo :: Maybe (E.Editor String String) -> CurrentState -> CurrentState
setEditorTo e = field @"csEditor" .~ e

applyNTimes :: Int -> (a -> a) -> a -> a
applyNTimes n f = foldr (.) id (replicate n f)

modifyTasks :: ([Task] -> [Task]) -> TodoList -> TodoList
modifyTasks _ MyDay = MyDay
modifyTasks f (TL name tasks) = TL name (f tasks)

deleteTask :: ID -> NEZ.Zipper TodoList -> NEZ.Zipper TodoList
deleteTask i = fmap (modifyTasks (filter (\t -> taskID t /= i)))

renameTask :: ID -> String -> NEZ.Zipper TodoList -> NEZ.Zipper TodoList
renameTask i newName = fmap (modifyTasks (fmap (\t -> if taskID t == i then t & field @"taskName" .~ newName else t)))

listToName :: TodoList -> String
listToName (TL name _) = name
listToName MyDay = "My Day"

getCurrentTasks :: NEZ.Zipper TodoList -> [Task]
getCurrentTasks z@(NEZ.Zipper _ curr _) = case curr of
    MyDay -> filter taskOnDay . concatMap getTasks . NEZ.toList $ z
    list -> getTasks list
    where
    getTasks MyDay = []
    getTasks (TL _ tasks) = tasks

listNames :: NEZ.Zipper TodoList -> [String]
listNames = map listToName . NEZ.toList

taskNames :: Z.Zipper Task -> [String]
taskNames = map taskName . Z.toList

currentListName :: NEZ.Zipper TodoList -> String
currentListName = listToName . NEZ.curr

nameForCurrentItem :: CurrentState -> String
nameForCurrentItem (CS _ Lists (Just _) _) = error "invariant violation: focused on lists with tasks zipper"
nameForCurrentItem (CS _ Tasks Nothing _) = error "invariant violation: focused on tasks with no tasks zipper"
nameForCurrentItem (CS _ Tasks (Just tasks) _) = maybe "" taskName (Z.getCurrent tasks)
nameForCurrentItem (CS lists Lists Nothing _) = currentListName lists

drawUI :: CurrentState -> [Widget String]
drawUI (CS z focus tasks editor) = [ui]
    where
    listsWidget = L.listMoveBy (NEZ.offset z) $ L.list "Lists" (Vec.fromList . listNames $ z) 1
    tasksWidget = case tasks of
        Just tasksZipper -> L.listMoveBy (Z.offset tasksZipper) $ L.list (currentListName z) (Vec.fromList . taskNames $ tasksZipper) 1
        Nothing -> L.list "Tasks" (Vec.fromList []) 1
    editWidget = case editor of
        Just editor' -> E.renderEditor (str . unlines) True editor'
        Nothing -> str ""
    label1 = str "Lists"
    label2 = str . currentListName $ z
    box1 = B.borderWithLabel label1 $
          hLimit 25 $
          vLimit 15 $
          vBox $ L.renderList (\_ -> C.hCenter . str) (focus == Lists) listsWidget : [editWidget | focus == Lists]
    box2 = B.borderWithLabel label2 $
          hLimit 25 $
          vLimit 15 $
          vBox $ L.renderList (\_ -> C.hCenter . str) (focus == Tasks) tasksWidget : [editWidget | focus == Tasks]
    emptyBox = B.border $
          hLimit 25 $
          vLimit 15 $
          fill ' '
    ui = C.hCenter . C.vCenter $ hBox [box1 , if focus == Tasks then box2 else emptyBox]

appEvent :: CurrentState -> T.BrickEvent String e -> T.EventM String (T.Next CurrentState)
appEvent cs@(CS _ focus _ Nothing) (T.VtyEvent e) =
    case e of
        V.EvKey V.KUp []         -> M.continue . moveUp $ cs
        V.EvKey (V.KChar 'k') [] -> M.continue . moveUp $ cs

        V.EvKey V.KDown []       -> M.continue . moveDown $ cs
        V.EvKey (V.KChar 'j') [] -> M.continue . moveDown $ cs

        V.EvKey V.KRight []      -> M.continue . moveRight $ cs
        V.EvKey (V.KChar 'l') [] -> M.continue . moveRight $ cs

        V.EvKey V.KLeft []       -> M.continue . moveLeft $ cs
        V.EvKey (V.KChar 'h') [] -> M.continue . moveLeft $ cs

        V.EvKey (V.KChar 'd') [] -> M.continue . deleteCurrentItem $ cs
        V.EvKey (V.KChar 'e') [] -> let
            editor = E.applyEdit TZ.gotoEOL $ E.editor ("edit " ++ show focus) (Just 1) (nameForCurrentItem cs)
            in M.continue $ setEditorTo (Just editor) cs

        V.EvKey V.KEsc [] -> M.halt cs
        _ -> M.continue cs
appEvent cs@(CS _ _ _ (Just editor)) (T.VtyEvent e) =
    case e of
        V.EvKey V.KEsc [] -> M.continue $ setEditorTo Nothing $ cs
        V.EvKey V.KEnter [] -> M.continue $ setEditorTo Nothing $ updateCurrentItem cs (mconcat $ E.getEditContents editor)
        e' -> do
            editor' <- E.handleEditorEvent e' editor
            M.continue $ setEditorTo (Just editor') cs
appEvent _ _ = error "FIXME: unhandled"

deleteCurrentItem :: CurrentState -> CurrentState
deleteCurrentItem (CS _ Lists (Just _) _) = error "invariant violation: focused on lists with tasks zipper"
deleteCurrentItem (CS _ Tasks Nothing _) = error "invariant violation: focused on tasks with no tasks zipper"
deleteCurrentItem (CS _ Tasks (Just (Z.Zipper (_:_) [])) _) = error "invariant violation: zipper with non empty left but empty right"
deleteCurrentItem (CS (NEZ.Zipper [] (TL _ _) []) Lists Nothing _) = error "invariant violation: MyDay list does not exist"
deleteCurrentItem cs@(CS (NEZ.Zipper _ MyDay _) Lists Nothing _) = cs
deleteCurrentItem cs@(CS (NEZ.Zipper l _ (x:xs)) Lists Nothing _) = cs & field @"csLists" .~ (NEZ.Zipper l x xs)
deleteCurrentItem cs@(CS (NEZ.Zipper (x:xs) _ []) Lists Nothing _) = cs & field @"csLists" .~ (NEZ.Zipper xs x [])
deleteCurrentItem cs@(CS _ Tasks (Just (Z.Zipper [] [])) _) = cs
deleteCurrentItem (CS z Tasks (Just (Z.Zipper l (t:_))) edit) = CS newListsZipper Tasks (Just newTasksZipper) edit
    where
    newListsZipper = deleteTask (taskID t) z
    newTasksZipper = applyNTimes (length l) Z.goRight . Z.fromList . getCurrentTasks $ newListsZipper

updateCurrentItem :: CurrentState -> String -> CurrentState
updateCurrentItem (CS _ Lists (Just _) _) _ = error "invariant violation: focused on lists with tasks zipper"
updateCurrentItem (CS _ Tasks Nothing _) _ = error "invariant violation: focused on tasks with no tasks zipper"
updateCurrentItem (CS _ Tasks (Just (Z.Zipper (_:_) [])) _) _ = error "invariant violation: zipper with non empty left but empty right"
updateCurrentItem (CS _ Tasks (Just (Z.Zipper [] [])) _) _ = error "invariant violation: trying to update a non-existent task"
updateCurrentItem cs@(CS (NEZ.Zipper _ MyDay _) Lists Nothing _) _ = cs
updateCurrentItem cs@(CS (NEZ.Zipper _ (TL _ tasks) _) Lists Nothing _) newName = cs & field @"csLists" %~ (NEZ.updateCurrent . const $ TL newName tasks)
updateCurrentItem (CS z Tasks (Just (Z.Zipper l (t:_))) edit) newName = CS newListsZipper Tasks (Just newTasksZipper) edit
    where
    newListsZipper = renameTask (taskID t) newName z
    newTasksZipper = applyNTimes (length l) Z.goRight . Z.fromList . getCurrentTasks $ newListsZipper

moveUp :: CurrentState -> CurrentState
moveUp (CS _ Lists (Just _) _) = error "invariant violation: focused on lists with tasks zipper"
moveUp (CS _ Tasks Nothing _) = error "invariant violation: focused on tasks with no tasks zipper"
moveUp cs@(CS _ Tasks (Just tasksZipper) _) = cs & field @"csTasks" .~ (Just $ Z.goLeft tasksZipper)
moveUp cs@(CS _ Lists Nothing _) = cs & field @"csLists" %~ NEZ.goLeft

moveDown :: CurrentState -> CurrentState
moveDown (CS _ Lists (Just _) _) = error "invariant violation: focused on lists with tasks zipper"
moveDown (CS _ Tasks Nothing _) = error "invariant violation: focused on tasks with no tasks zipper"
moveDown cs@(CS _ Tasks (Just tasksZipper) _) = cs & field @"csTasks" .~ (Just $ Z.goRight tasksZipper)
moveDown cs@(CS _ Lists Nothing _) = cs & field @"csLists" %~ NEZ.goRight

moveLeft :: CurrentState -> CurrentState
moveLeft cs = cs & field @"csFocus" .~ Lists & field @"csTasks" .~ Nothing

moveRight :: CurrentState -> CurrentState
moveRight cs = cs & field @"csFocus" .~ Tasks & field @"csTasks" .~ Just tasksZipper
    where
    tasksZipper = Z.fromList . getCurrentTasks $ cs ^. field @"csLists"

theMap :: A.AttrMap
theMap = A.attrMap V.defAttr
    [ (L.listAttr,                V.white `on` V.blue)
    , (L.listSelectedAttr,        V.white `on` V.black)
    , (L.listSelectedFocusedAttr, V.blue `on` V.white)
    ]

theApp :: M.App CurrentState e String
theApp =
    M.App { M.appDraw = drawUI
          , M.appChooseCursor = M.showFirstCursor
          , M.appHandleEvent = appEvent
          , M.appStartEvent = return
          , M.appAttrMap = const theMap
          }

foo :: Task
foo = Task (ID 1) "Foo" True

bar :: Task
bar = Task (ID 2) "Bar" False

baz :: Task
baz = Task (ID 3) "Baz" True

blah :: Task
blah = Task (ID 4) "Blah" False

listTodo :: TodoList
listTodo = TL "Todo" [foo, bar, blah]

listProjects :: TodoList
listProjects = TL "Projects" [baz]

initialState :: CurrentState
initialState = CS (NEZ.Zipper [MyDay] listTodo [listProjects]) Lists Nothing Nothing

main :: IO ()
main = void $ M.defaultMain theApp initialState
