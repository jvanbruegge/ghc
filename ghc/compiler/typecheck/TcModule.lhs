%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[TcModule]{Typechecking a whole module}

\begin{code}
module TcModule (
	typecheckModule, typecheckIface, typecheckStmt, TcResults(..)
    ) where

#include "HsVersions.h"

import CmdLineOpts	( DynFlag(..), DynFlags, opt_PprStyle_Debug )
import HsSyn		( HsBinds(..), MonoBinds(..), HsDecl(..), HsExpr(..),
			  Stmt(..), InPat(..), HsMatchContext(..),
			  isIfaceRuleDecl, nullBinds, andMonoBindList, mkSimpleMatch
			)
import HsTypes		( toHsType )
import PrelNames	( SyntaxMap, mAIN_Name, mainName, ioTyConName, printName,
			  returnIOName, bindIOName, failIOName, 
			  itName
			)
import MkId		( unsafeCoerceId )
import RnHsSyn		( RenamedHsBinds, RenamedHsDecl, RenamedStmt )
import TcHsSyn		( TypecheckedMonoBinds, TypecheckedHsExpr,
			  TypecheckedForeignDecl, TypecheckedRuleDecl,
			  zonkTopBinds, zonkForeignExports, zonkRules, mkHsLet,
			  zonkExpr, zonkIdBndr
			)


import TcMonad
import TcType		( newTyVarTy, zonkTcType, tcInstType )
import TcMatches	( tcStmtsAndThen )
import TcUnify		( unifyTauTy )
import Inst		( emptyLIE, plusLIE )
import TcBinds		( tcTopBinds )
import TcClassDcl	( tcClassDecls2 )
import TcDefaults	( tcDefaults, defaultDefaultTys )
import TcEnv		( TcEnv, RecTcEnv, InstInfo, tcExtendGlobalValEnv, tcLookup_maybe,
			  isLocalThing, tcSetEnv, tcSetInstEnv, initTcEnv, getTcGEnv,
			  tcExtendGlobalTypeEnv, tcLookupGlobalId, tcLookupTyCon,
			  TcTyThing(..), tcLookupId
			)
import TcRules		( tcIfaceRules, tcSourceRules )
import TcForeign	( tcForeignImports, tcForeignExports )
import TcIfaceSig	( tcInterfaceSigs )
import TcInstDcls	( tcInstDecls1, tcInstDecls2 )
import TcSimplify	( tcSimplifyTop )
import TcTyClsDecls	( tcTyAndClassDecls )

import CoreUnfold	( unfoldingTemplate, hasUnfolding )
import TysWiredIn	( mkListTy, unitTy )
import Type		( funResultTy, splitForAllTys, 
			  liftedTypeKind, mkTyConApp, tidyType )
import ErrUtils		( printErrorsAndWarnings, errorsFound, dumpIfSet_dyn, showPass )
import Id		( Id, idType, idName, isLocalId, idUnfolding )
import Module           ( Module, isHomeModule, moduleName )
import Name		( Name, toRdrName, isGlobalName )
import Name		( nameEnvElts, lookupNameEnv )
import TyCon		( tyConGenInfo )
import Util
import BasicTypes       ( EP(..), Fixity, RecFlag(..) )
import SrcLoc		( noSrcLoc )
import Outputable
import HscTypes		( PersistentCompilerState(..), HomeSymbolTable, 
			  PackageTypeEnv, ModIface(..),
			  TypeEnv, extendTypeEnvList, 
		          TyThing(..), implicitTyThingIds, 
			  mkTypeEnv
			)
import Rules ( ruleBaseIds )
import VarSet
\end{code}


%************************************************************************
%*									*
\subsection{The stmt interface}
%*									*
%************************************************************************

\begin{code}
typecheckStmt :: DynFlags
	      -> PersistentCompilerState
	      -> HomeSymbolTable
	      -> TypeEnv		-- The interactive context's type envt 
	      -> PrintUnqualified	-- For error printing
	      -> Module			-- Is this really needed
	      -> [Name]			-- Names bound by the Stmt (empty for expressions)
	      -> (SyntaxMap,
		  RenamedStmt, 		-- The stmt itself
	          [RenamedHsDecl])	-- Plus extra decls it sucked in from interface files
	      -> IO (Maybe (PersistentCompilerState, TypecheckedHsExpr, [Id]))
			-- The returned [Name] is the same as the input except for
			-- ExprStmt, in which case the returned [Name] is [itName]

typecheckStmt dflags pcs hst ic_type_env unqual this_mod names (syn_map, stmt, iface_decls)
  = typecheck dflags syn_map pcs hst unqual $

 	 -- use the default default settings, i.e. [Integer, Double]
    tcSetDefaultTys defaultDefaultTys $

	-- Typecheck the extra declarations
    fixTc (\ ~(unf_env, _, _, _, _) ->
	tcImports unf_env pcs hst get_fixity this_mod iface_decls
    )			`thenTc` \ (env, new_pcs, local_inst_info, deriv_binds, local_rules) ->
    ASSERT( null local_inst_info && nullBinds deriv_binds && null local_rules )

    tcSetEnv env				$
    tcExtendGlobalTypeEnv ic_type_env		$

	-- The real work is done here
    tcUserStmt names stmt 		`thenTc` \ (expr, bound_ids) ->

    traceTc (text "tcs 1") `thenNF_Tc_`
    zonkExpr expr			`thenNF_Tc` \ zonked_expr ->
    mapNF_Tc zonkIdBndr bound_ids	`thenNF_Tc` \ zonked_ids ->

    ioToTc (dumpIfSet_dyn dflags Opt_D_dump_tc "Bound Ids" (vcat (map ppr zonked_ids)))	`thenNF_Tc_`
    ioToTc (dumpIfSet_dyn dflags Opt_D_dump_tc "Typechecked" (ppr zonked_expr))		`thenNF_Tc_`

    returnTc (new_pcs, zonked_expr, zonked_ids)

  where
    get_fixity :: Name -> Maybe Fixity
    get_fixity n = pprPanic "typecheckExpr" (ppr n)
\end{code}

Here is the grand plan, implemented in tcUserStmt

	What you type			The IO [HValue] that hscStmt returns
	-------------			------------------------------------
	let pat = expr		==> 	let pat = expr in return [coerce HVal x, coerce HVal y, ...]
					bindings: [x,y,...]

	pat <- expr		==> 	expr >>= \ pat -> return [coerce HVal x, coerce HVal y, ...]
					bindings: [x,y,...]

	expr (of IO type)	==>	expr >>= \ v -> return [v]
	  [NB: result not printed]	bindings: [it]
	  

	expr (of non-IO type, 
	  result showable)	==>	let v = expr in print v >> return [v]
	  				bindings: [it]

	expr (of non-IO type, 
	  result not showable)	==>	error


\begin{code}
tcUserStmt :: [Name] -> RenamedStmt -> TcM (TypecheckedHsExpr, [Id])

tcUserStmt names (ExprStmt expr loc)
  = ASSERT( null names )
    tryTc_ (traceTc (text "tcs 1b") `thenNF_Tc_`
		tc_stmts [itName] [LetStmt (MonoBind the_bind [] NonRecursive),
			       ExprStmt (HsApp (HsVar printName) (HsVar itName)) loc])
	   (    traceTc (text "tcs 1a") `thenNF_Tc_`
		tc_stmts [itName] [BindStmt (VarPatIn itName) expr loc])
  where
    the_bind = FunMonoBind itName False [mkSimpleMatch [] expr Nothing loc] loc

tcUserStmt names stmt
  = tc_stmts names [stmt]
    

tc_stmts names stmts
  = tcLookupGlobalId returnIOName	`thenNF_Tc` \ return_id ->
    tcLookupGlobalId bindIOName		`thenNF_Tc` \ bind_id ->
    tcLookupGlobalId failIOName		`thenNF_Tc` \ fail_id ->
    tcLookupTyCon ioTyConName		`thenNF_Tc` \ ioTyCon ->
    newTyVarTy liftedTypeKind		`thenNF_Tc` \ res_ty ->
    let
	io_ty = (\ ty -> mkTyConApp ioTyCon [ty], res_ty)

		-- mk_return builds the expression
		--	returnIO @ [()] [coerce () x, ..,  coerce () z]
	mk_return ids = HsApp (TyApp (HsVar return_id) [mkListTy unitTy]) 
			      (ExplicitListOut unitTy (map mk_item ids))

	mk_item id = HsApp (TyApp (HsVar unsafeCoerceId) [idType id, unitTy])
		  	   (HsVar id)
    in

    traceTc (text "tcs 2") `thenNF_Tc_`
    tcStmtsAndThen combine DoExpr io_ty stmts	(
	-- Look up the names right in the middle,
	-- where they will all be in scope
	mapNF_Tc tcLookupId names			`thenNF_Tc` \ ids ->
	returnTc ((ids, [ExprStmt (mk_return ids) noSrcLoc]), emptyLIE)
    )							`thenTc` \ ((ids, tc_stmts), lie) ->

	-- Simplify the context right here, so that we fail
	-- if there aren't enough instances.  Notably, when we see
	--		e
	-- we use tryTc_ to try		it <- e
	-- and then			let it = e
	-- It's the simplify step that rejects the first.

    traceTc (text "tcs 3") `thenNF_Tc_`
    tcSimplifyTop lie			`thenTc` \ const_binds ->
    traceTc (text "tcs 4") `thenNF_Tc_`

    returnTc (mkHsLet const_binds $
	      HsDoOut DoExpr tc_stmts return_id bind_id fail_id 
		      (mkTyConApp ioTyCon [mkListTy unitTy]) noSrcLoc,
	      ids)
  where
    combine stmt (ids, stmts) = (ids, stmt:stmts)
\end{code}


%************************************************************************
%*									*
\subsection{Typechecking a module}
%*									*
%************************************************************************

\begin{code}
typecheckModule
	:: DynFlags
	-> PersistentCompilerState
	-> HomeSymbolTable
	-> ModIface		-- Iface for this module
	-> PrintUnqualified	-- For error printing
	-> (SyntaxMap, [RenamedHsDecl])
	-> IO (Maybe (PersistentCompilerState, TcResults))
			-- The new PCS is Augmented with imported information,
						-- (but not stuff from this module)

data TcResults
  = TcResults {
	-- All these fields have info *just for this module*
	tc_env	   :: TypeEnv,			-- The top level TypeEnv
	tc_binds   :: TypecheckedMonoBinds,	-- Bindings
	tc_fords   :: [TypecheckedForeignDecl], -- Foreign import & exports.
	tc_rules   :: [TypecheckedRuleDecl]	-- Transformation rules
    }


typecheckModule dflags pcs hst mod_iface unqual (syn_map, decls)
  = do	{ maybe_tc_result <- typecheck dflags syn_map pcs hst unqual $
			     tcModule pcs hst get_fixity this_mod decls
	; printTcDump dflags maybe_tc_result
	; return maybe_tc_result }
  where
    this_mod   = mi_module   mod_iface
    fixity_env = mi_fixities mod_iface

    get_fixity :: Name -> Maybe Fixity
    get_fixity nm = lookupNameEnv fixity_env nm


tcModule :: PersistentCompilerState
	 -> HomeSymbolTable
	 -> (Name -> Maybe Fixity)
	 -> Module
	 -> [RenamedHsDecl]
	 -> TcM (PersistentCompilerState, TcResults)

tcModule pcs hst get_fixity this_mod decls
  = fixTc (\ ~(unf_env, _, _) ->
		-- Loop back the final environment, including the fully zonkec
		-- versions of bindings from this module.  In the presence of mutual
		-- recursion, interface type signatures may mention variables defined
		-- in this module, which is why the knot is so big

		-- Type-check the type and class decls, and all imported decls
	tcImports unf_env pcs hst get_fixity this_mod decls	
				`thenTc` \ (env, new_pcs, local_insts, deriv_binds, local_rules) ->

    	tcSetEnv env				$

        -- Foreign import declarations next
        traceTc (text "Tc4")			`thenNF_Tc_`
	tcForeignImports decls			`thenTc`    \ (fo_ids, foi_decls) ->
	tcExtendGlobalValEnv fo_ids		$
    
	-- Default declarations
	tcDefaults decls			`thenTc` \ defaulting_tys ->
	tcSetDefaultTys defaulting_tys 		$
	
	-- Value declarations next.
	-- We also typecheck any extra binds that came out of the "deriving" process
	traceTc (text "Default types" <+> ppr defaulting_tys)	`thenNF_Tc_`
        traceTc (text "Tc5")				`thenNF_Tc_`
	tcTopBinds (val_binds `ThenBinds` deriv_binds)	`thenTc` \ ((val_binds, env), lie_valdecls) ->
	
     	-- Second pass over class and instance declarations, 
	-- plus rules and foreign exports, to generate bindings
	tcSetEnv env				$
	tcInstDecls2  local_insts		`thenNF_Tc` \ (lie_instdecls, inst_binds) ->
	tcClassDecls2 this_mod tycl_decls	`thenNF_Tc` \ (lie_clasdecls, cls_dm_binds) ->
	tcForeignExports decls			`thenTc`    \ (lie_fodecls,   foe_binds, foe_decls) ->
	tcSourceRules source_rules		`thenNF_Tc` \ (lie_rules,     more_local_rules) ->
	
	     -- Deal with constant or ambiguous InstIds.  How could
	     -- there be ambiguous ones?  They can only arise if a
	     -- top-level decl falls under the monomorphism
	     -- restriction, and no subsequent decl instantiates its
	     -- type.  (Usually, ambiguous type variables are resolved
	     -- during the generalisation step.)
	let
	    lie_alldecls = lie_valdecls	 `plusLIE`
			   lie_instdecls `plusLIE`
			   lie_clasdecls `plusLIE`
			   lie_fodecls	 `plusLIE`
			   lie_rules
	in
        traceTc (text "Tc6")				`thenNF_Tc_`
	tcSimplifyTop lie_alldecls			`thenTc` \ const_inst_binds ->
	
		-- CHECK THAT main IS DEFINED WITH RIGHT TYPE, IF REQUIRED
	tcCheckMain this_mod		`thenTc_`
	
	    -- Backsubstitution.    This must be done last.
	    -- Even tcSimplifyTop may do some unification.
	let
	    all_binds = val_binds		`AndMonoBinds`
			    inst_binds		`AndMonoBinds`
			    cls_dm_binds	`AndMonoBinds`
			    const_inst_binds	`AndMonoBinds`
			    foe_binds
	in
 	traceTc (text "Tc7")		`thenNF_Tc_`
	zonkTopBinds all_binds		`thenNF_Tc` \ (all_binds', final_env)  ->
	tcSetEnv final_env		$
		-- zonkTopBinds puts all the top-level Ids into the tcGEnv
 	traceTc (text "Tc8")		`thenNF_Tc_`
	zonkForeignExports foe_decls	`thenNF_Tc` \ foe_decls' ->
 	traceTc (text "Tc9")		`thenNF_Tc_`
	zonkRules more_local_rules	`thenNF_Tc` \ more_local_rules' ->
	
	
	let	local_things = filter (isLocalThing this_mod) (nameEnvElts (getTcGEnv final_env))
	
		-- Create any necessary "implicit" bindings (data constructors etc)
		-- Should we create bindings for dictionary constructors?
		-- They are always fully applied, and the bindings are just there
		-- to support partial applications. But it's easier to let them through.
		implicit_binds = andMonoBindList [ CoreMonoBind id (unfoldingTemplate unf)
						 | id <- implicitTyThingIds local_things
						 , let unf = idUnfolding id
						 , hasUnfolding unf
						 ]
	
		local_type_env :: TypeEnv
		local_type_env = mkTypeEnv local_things
		    
		all_local_rules = local_rules ++ more_local_rules'
	in  
	traceTc (text "Tc10")		`thenNF_Tc_`
	returnTc (final_env,
		  new_pcs,
		  TcResults { tc_env     = local_type_env,
			      tc_binds   = implicit_binds `AndMonoBinds` all_binds', 
			      tc_fords   = foi_decls ++ foe_decls',
			      tc_rules   = all_local_rules
			    }
	)
    )			`thenTc` \ (_, pcs, tc_result) ->
    returnTc (pcs, tc_result)
  where
    tycl_decls   = [d | TyClD d <- decls]
    val_binds    = foldr ThenBinds EmptyBinds [binds | ValD binds <- decls]
    source_rules = [d | RuleD d <- decls, not (isIfaceRuleDecl d)]
\end{code}


%************************************************************************
%*									*
\subsection{Typechecking interface decls}
%*									*
%************************************************************************

\begin{code}
typecheckIface
	:: DynFlags
	-> PersistentCompilerState
	-> HomeSymbolTable
	-> ModIface		-- Iface for this module (just module & fixities)
	-> (SyntaxMap, [RenamedHsDecl])
	-> IO (Maybe (PersistentCompilerState, TypeEnv, [TypecheckedRuleDecl]))
			-- The new PCS is Augmented with imported information,
			-- (but not stuff from this module).
			-- The TcResults returned contains only the environment
			-- and rules.


typecheckIface dflags pcs hst mod_iface (syn_map, decls)
  = do	{ maybe_tc_stuff <- typecheck dflags syn_map pcs hst alwaysQualify $
			    tcIfaceImports pcs hst get_fixity this_mod decls
	; printIfaceDump dflags maybe_tc_stuff
	; return maybe_tc_stuff }
  where
    this_mod   = mi_module   mod_iface
    fixity_env = mi_fixities mod_iface

    get_fixity :: Name -> Maybe Fixity
    get_fixity nm = lookupNameEnv fixity_env nm

    tcIfaceImports pcs hst get_fixity this_mod decls
	= fixTc (\ ~(unf_env, _, _, _, _) ->
	      tcImports unf_env pcs hst get_fixity this_mod decls
          )	`thenTc` \ (env, new_pcs, local_inst_info, 
			    deriv_binds, local_rules) ->
	  ASSERT(nullBinds deriv_binds)
	  let 
	      local_things = filter (isLocalThing this_mod) 
				 	(nameEnvElts (getTcGEnv env))
	      local_type_env :: TypeEnv
	      local_type_env = mkTypeEnv local_things
	  in

	  -- throw away local_inst_info
          returnTc (new_pcs, local_type_env, local_rules)


tcImports :: RecTcEnv
	  -> PersistentCompilerState
	  -> HomeSymbolTable
	  -> (Name -> Maybe Fixity)
	  -> Module
	  -> [RenamedHsDecl]
	  -> TcM (TcEnv, PersistentCompilerState, [InstInfo], 
			 RenamedHsBinds, [TypecheckedRuleDecl])

-- tcImports is a slight mis-nomer.  
-- It deals with everythign that could be an import:
--	type and class decls
--	interface signatures
--	instance decls
--	rule decls
-- These can occur in source code too, of course

tcImports unf_env pcs hst get_fixity this_mod decls
   	  -- (unf_env :: RecTcEnv) is used for type-checking interface pragmas
	  -- which is done lazily [ie failure just drops the pragma
	  -- without having any global-failure effect].
	  -- 
	  -- unf_env is also used to get the pragama info
	  -- for imported dfuns and default methods

  = checkNoErrsTc $
	-- tcImports recovers internally, but if anything gave rise to
	-- an error we'd better stop now, to avoid a cascade
	
    traceTc (text "Tc1")			`thenNF_Tc_`
    tcTyAndClassDecls unf_env tycl_decls	`thenTc` \ env ->
    tcSetEnv env 				$
    
    	-- Typecheck the instance decls, includes deriving
    traceTc (text "Tc2")	`thenNF_Tc_`
    tcInstDecls1 (pcs_insts pcs) (pcs_PRS pcs) 
    	     hst unf_env get_fixity this_mod 
    	     decls			`thenTc` \ (new_pcs_insts, inst_env, local_insts, deriv_binds) ->
    tcSetInstEnv inst_env			$
    
    -- Interface type signatures
    -- We tie a knot so that the Ids read out of interfaces are in scope
    --   when we read their pragmas.
    -- What we rely on is that pragmas are typechecked lazily; if
    --   any type errors are found (ie there's an inconsistency)
    --   we silently discard the pragma
    traceTc (text "Tc3")			`thenNF_Tc_`
    tcInterfaceSigs unf_env this_mod tycl_decls	`thenTc` \ sig_ids ->
    tcExtendGlobalValEnv sig_ids		$
    
    
    tcIfaceRules (pcs_rules pcs) this_mod iface_rules	`thenNF_Tc` \ (new_pcs_rules, local_rules) ->
    	-- When relinking this module from its interface-file decls
    	-- we'll have IfaceRules that are in fact local to this module
    	-- That's the reason we we get any local_rules out here
    
    tcGetEnv						`thenTc` \ unf_env ->
    let
        all_things = nameEnvElts (getTcGEnv unf_env)
    
         -- sometimes we're compiling in the context of a package module
         -- (on the GHCi command line, for example).  In this case, we
         -- want to treat everything we pulled in as an imported thing.
        imported_things
    	  | isHomeModule this_mod
    	  = filter (not . isLocalThing this_mod) all_things
    	  | otherwise
    	  = all_things
    
        new_pte :: PackageTypeEnv
        new_pte = extendTypeEnvList (pcs_PTE pcs) imported_things
        
        new_pcs :: PersistentCompilerState
        new_pcs = pcs { pcs_PTE   = new_pte,
    		        pcs_insts = new_pcs_insts,
    		        pcs_rules = new_pcs_rules
      	          }
    in
    returnTc (unf_env, new_pcs, local_insts, deriv_binds, local_rules)
  where
    tycl_decls  = [d | TyClD d <- decls]
    iface_rules = [d | RuleD d <- decls, isIfaceRuleDecl d]
\end{code}    


%************************************************************************
%*									*
\subsection{Checking the type of main}
%*									*
%************************************************************************

We must check that in module Main,
	a) main is defined
	b) main :: forall a1...an. IO t,  for some type t

If we have
	main = error "Urk"
then the type of main will be 
	main :: forall a. a
and that should pass the test too.  

So we just instantiate the type and unify with IO t, and declare 
victory if doing so succeeds.

\begin{code}
tcCheckMain :: Module -> TcM ()
tcCheckMain this_mod
  | not (moduleName this_mod == mAIN_Name )
  = returnTc ()

  | otherwise
  =	-- First unify the main_id with IO t, for any old t
    tcLookup_maybe mainName		`thenNF_Tc` \ maybe_thing ->
    case maybe_thing of
	Just (ATcId main_id) -> check_main_ty (idType main_id)
	other		     -> addErrTc noMainErr	
  where
    check_main_ty main_ty
      = tcInstType main_ty		`thenNF_Tc` \ (tvs, theta, main_tau) ->
	newTyVarTy liftedTypeKind	`thenNF_Tc` \ arg_ty ->
	tcLookupTyCon ioTyConName	`thenNF_Tc` \ ioTyCon ->
	tcAddErrCtxtM (mainTypeCtxt main_ty)	$
	if not (null theta) then 
		failWithTc empty	-- Context has the error message
	else
	unifyTauTy main_tau (mkTyConApp ioTyCon [arg_ty])

mainTypeCtxt main_ty tidy_env 
  = zonkTcType main_ty		`thenNF_Tc` \ main_ty' ->
    returnNF_Tc (tidy_env, ptext SLIT("`main' has the illegal type") <+> 
	 		 	 quotes (ppr (tidyType tidy_env main_ty')))

noMainErr = hsep [ptext SLIT("Module") <+> quotes (ppr mAIN_Name), 
	  	  ptext SLIT("must include a definition for") <+> quotes (ptext SLIT("main"))]
\end{code}


%************************************************************************
%*									*
\subsection{Interfacing the Tc monad to the IO monad}
%*									*
%************************************************************************

\begin{code}
typecheck :: DynFlags
	  -> SyntaxMap
	  -> PersistentCompilerState
	  -> HomeSymbolTable
	  -> PrintUnqualified	-- For error printing
	  -> TcM r
	  -> IO (Maybe r)

typecheck dflags syn_map pcs hst unqual thing_inside 
 = do	{ showPass dflags "Typechecker";
	; env <- initTcEnv syn_map hst (pcs_PTE pcs)

	; (maybe_tc_result, errs) <- initTc dflags env thing_inside

	; printErrorsAndWarnings unqual errs

	; if errorsFound errs then 
             return Nothing 
           else 
             return maybe_tc_result
	}
\end{code}


%************************************************************************
%*									*
\subsection{Dumping output}
%*									*
%************************************************************************

\begin{code}
printTcDump dflags Nothing = return ()
printTcDump dflags (Just (_, results))
  = do dumpIfSet_dyn dflags Opt_D_dump_types 
                     "Type signatures" (dump_sigs (tc_env results))
       dumpIfSet_dyn dflags Opt_D_dump_tc    
                     "Typechecked" (dump_tc results) 

printIfaceDump dflags Nothing = return ()
printIfaceDump dflags (Just (_, env, rules))
  = do dumpIfSet_dyn dflags Opt_D_dump_types 
                     "Type signatures" (dump_sigs env)
       dumpIfSet_dyn dflags Opt_D_dump_tc    
                     "Typechecked" (dump_iface env rules) 

dump_tc results
  = vcat [ppr (tc_binds results),
	  pp_rules (tc_rules results),
	  ppr_gen_tycons [tc | ATyCon tc <- nameEnvElts (tc_env results)]
    ]

dump_iface env rules
  = vcat [pp_rules rules,
	  ppr_gen_tycons [tc | ATyCon tc <- nameEnvElts env]
    ]

dump_sigs env	-- Print type signatures
  = 	-- Convert to HsType so that we get source-language style printing
	-- And sort by RdrName
    vcat $ map ppr_sig $ sortLt lt_sig $
    [ (toRdrName id, toHsType (idType id))
    | AnId id <- nameEnvElts env,
      want_sig id
    ]
  where
    lt_sig (n1,_) (n2,_) = n1 < n2
    ppr_sig (n,t)        = ppr n <+> dcolon <+> ppr t

    want_sig id | opt_PprStyle_Debug = True
	        | otherwise	     = isLocalId id && isGlobalName (idName id)
	-- isLocalId ignores data constructors, records selectors etc
	-- The isGlobalName ignores local dictionary and method bindings
	-- that the type checker has invented.  User-defined things have
	-- Global names.

ppr_gen_tycons tcs = vcat [ptext SLIT("{-# Generic type constructor details"),
			   vcat (map ppr_gen_tycon tcs),
		   	   ptext SLIT("#-}")
		     ]

-- x&y are now Id's, not CoreExpr's 
ppr_gen_tycon tycon 
  | Just ep <- tyConGenInfo tycon
  = (ppr tycon <> colon) $$ nest 4 (ppr_ep ep)

  | otherwise = ppr tycon <> colon <+> ptext SLIT("Not derivable")

ppr_ep (EP from to)
  = vcat [ ptext SLIT("Rep type:") <+> ppr (funResultTy from_tau),
	   ptext SLIT("From:") <+> ppr (unfoldingTemplate (idUnfolding from)),
	   ptext SLIT("To:")   <+> ppr (unfoldingTemplate (idUnfolding to))
    ]
  where
    (_,from_tau) = splitForAllTys (idType from)

pp_rules [] = empty
pp_rules rs = vcat [ptext SLIT("{-# RULES"),
		    nest 4 (vcat (map ppr rs)),
		    ptext SLIT("#-}")]
\end{code}
