%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnIfaces]{Cacheing and Renaming of Interfaces}

\begin{code}
module RnIfaces (
	getInterfaceExports,
	getImportedInstDecls,
	getSpecialInstModules, getDeferredDataDecls,
	importDecl, recordSlurp,
	getImportVersions, getSlurpedNames, getRnStats, getImportedFixities,

	checkUpToDate,

	getDeclBinders,
	mkSearchPath
    ) where

#include "HsVersions.h"

import CmdLineOpts	( opt_PruneTyDecls,  opt_PruneInstDecls, 
			  opt_D_show_rn_imports, opt_IgnoreIfacePragmas
			)
import HsSyn		( HsDecl(..), TyClDecl(..), InstDecl(..), IfaceSig(..), 
			  HsType(..), ConDecl(..), IE(..), ConDetails(..), Sig(..),
			  FixitySig(..),
			  hsDeclName, countTyClDecls, isDataDecl, isClassOpSig
			)
import BasicTypes	( Version, NewOrData(..) )
import RdrHsSyn		( RdrNameHsDecl, RdrNameInstDecl, RdrNameTyClDecl,
			)
import RnEnv		( newImportedGlobalName, newImportedGlobalFromRdrName, 
			  addImplicitOccsRn, pprAvail,
			  availName, availNames, addAvailToNameSet
			)
import RnSource		( rnHsSigType )
import RnMonad
import RnHsSyn          ( RenamedHsDecl )
import ParseIface	( parseIface, IfaceStuff(..) )

import FiniteMap	( FiniteMap, sizeFM, emptyFM, delFromFM,
			  lookupFM, addToFM, addToFM_C, addListToFM, 
			  fmToList
			)
import Name		( Name {-instance NamedThing-},
			  nameModule, isLocallyDefined,
			  isWiredInName, maybeWiredInTyConName,
			  maybeWiredInIdName, nameUnique, NamedThing(..),
			  pprEncodedFS
			 )
import Module		( Module, mkBootModule, moduleString, pprModule, 
			  mkDynamicModule, moduleIfaceFlavour, bootFlavour, hiFile,
			  moduleUserString, moduleFS, setModuleFlavour
			)
import RdrName		( RdrName, rdrNameOcc )
import NameSet
import Id		( idType, isDataConId_maybe )
import DataCon		( dataConTyCon, dataConType )
import TyCon		( TyCon, tyConDataCons, isSynTyCon, getSynTyConDefn )
import Type		( namesOfType )
import Var		( Id )
import SrcLoc		( mkSrcLoc, SrcLoc )
import PrelMods		( pREL_GHC )
import PrelInfo		( cCallishTyKeys, thinAirModules )
import Bag
import Maybes		( MaybeErr(..), maybeToBool )
import ListSetOps	( unionLists )
import Outputable
import Unique		( Unique )
import StringBuffer     ( StringBuffer, hGetStringBuffer )
import FastString	( mkFastString )
import Outputable

import IO	( isDoesNotExistError )
import List	( nub )
\end{code}



%*********************************************************
%*							*
\subsection{Statistics}
%*							*
%*********************************************************

\begin{code}
getRnStats :: [RenamedHsDecl] -> RnMG SDoc
getRnStats all_decls
  = getIfacesRn 		`thenRn` \ ifaces ->
    let
	n_mods	    = sizeFM (iModMap ifaces)

	decls_imported = filter is_imported_decl all_decls

	decls_read     = [decl | (_, avail, decl, True) <- nameEnvElts (iDecls ifaces),
					-- Data, newtype, and class decls are in the decls_fm
					-- under multiple names; the tycon/class, and each
					-- constructor/class op too.
					-- The 'True' selects just the 'main' decl
				 not (isLocallyDefined (availName avail))
			     ]

	(cd_rd, dd_rd, add_rd, nd_rd, and_rd, sd_rd, vd_rd,     _) = count_decls decls_read
	(cd_sp, dd_sp, add_sp, nd_sp, and_sp, sd_sp, vd_sp, id_sp) = count_decls decls_imported

	(unslurped_insts, _)  = iDefInsts ifaces
	inst_decls_unslurped  = length (bagToList unslurped_insts)
	inst_decls_read	      = id_sp + inst_decls_unslurped

	stats = vcat 
		[int n_mods <> text " interfaces read",
		 hsep [ int cd_sp, text "class decls imported, out of", 
		        int cd_rd, text "read"],
		 hsep [ int dd_sp, text "data decls imported (of which", int add_sp, 
			text "abstractly), out of",  
			int dd_rd, text "read"],
		 hsep [ int nd_sp, text "newtype decls imported (of which", int and_sp, 
			text "abstractly), out of",  
		        int nd_rd, text "read"],
		 hsep [int sd_sp, text "type synonym decls imported, out of",  
		        int sd_rd, text "read"],
		 hsep [int vd_sp, text "value signatures imported, out of",  
		        int vd_rd, text "read"],
		 hsep [int id_sp, text "instance decls imported, out of",  
		        int inst_decls_read, text "read"]
		]
    in
    returnRn (hcat [text "Renamer stats: ", stats])

is_imported_decl (DefD _) = False
is_imported_decl (ValD _) = False
is_imported_decl decl     = not (isLocallyDefined (hsDeclName decl))

count_decls decls
  = -- pprTrace "count_decls" (ppr  decls
    --
    --			    $$
    --			    text "========="
    --			    $$
    --			    ppr imported_decls
    --	) $
    (class_decls, 
     data_decls,    abstract_data_decls,
     newtype_decls, abstract_newtype_decls,
     syn_decls, 
     val_decls, 
     inst_decls)
  where
    tycl_decls = [d | TyClD d <- decls]
    (class_decls, data_decls, newtype_decls, syn_decls) = countTyClDecls tycl_decls
    abstract_data_decls    = length [() | TyData DataType _ _ _ [] _ _ _ <- tycl_decls]
    abstract_newtype_decls = length [() | TyData NewType  _ _ _ [] _ _ _ <- tycl_decls]

    val_decls     = length [() | SigD _	  <- decls]
    inst_decls    = length [() | InstD _  <- decls]

\end{code}    

%*********************************************************
%*							*
\subsection{Loading a new interface file}
%*							*
%*********************************************************

\begin{code}
loadHomeInterface :: SDoc -> Name -> RnMG (Module, Ifaces)
loadHomeInterface doc_str name
  = loadInterface doc_str (nameModule name)

loadInterface :: SDoc -> Module -> RnMG (Module, Ifaces)
loadInterface doc_str load_mod
 = getIfacesRn 		`thenRn` \ ifaces ->
   let
	hi_boot_wanted	     = bootFlavour (moduleIfaceFlavour load_mod)
	mod_map  	     = iModMap ifaces
	(insts, tycls_names) = iDefInsts ifaces
	
   in
	-- CHECK WHETHER WE HAVE IT ALREADY
   case lookupFM mod_map load_mod of {
	Just (existing_hif, _, _) 
		| hi_boot_wanted || not (bootFlavour existing_hif)
		-> 	-- Already in the cache, and new version is no better than old,
			-- so don't re-read it
		    returnRn (setModuleFlavour existing_hif load_mod, ifaces) ;
	other ->

	-- READ THE MODULE IN
   findAndReadIface doc_str load_mod		`thenRn` \ read_result ->
   case read_result of {
	Nothing | not hi_boot_wanted && load_mod `elem` thinAirModules
		-> -- Hack alert!  When compiling PrelBase we have to load the
		   -- decls for packCString# and friends; they are 'thin-air' Ids
		   -- (see PrelInfo.lhs).  So if we don't find the HiFile we quietly
		   -- look for a .hi-boot file instead, and use that
		   --
		   -- NB this causes multiple "failed" attempts to read PrelPack,
		   --    which makes curious reading with -dshow-rn-trace, but
		   --    there's no harm done
		   loadInterface doc_str (mkBootModule load_mod)

	       
		| otherwise
		-> 	-- Not found, so add an empty export env to the Ifaces map
			-- so that we don't look again
		   let
			new_mod_map = addToFM mod_map load_mod (hiFile, 0, [])
			new_ifaces = ifaces { iModMap = new_mod_map }
		   in
		   setIfacesRn new_ifaces		`thenRn_`
		   failWithRn (load_mod, new_ifaces) (noIfaceErr load_mod) ;

	-- Found and parsed!
	Just (the_mod, ParsedIface mod_vers usages exports rd_inst_mods rd_decls rd_insts) ->


	-- LOAD IT INTO Ifaces
	-- First set the module

	-- NB: *first* we do loadDecl, so that the provenance of all the locally-defined
	---    names is done correctly (notably, whether this is an .hi file or .hi-boot file).
	--     If we do loadExport first the wrong info gets into the cache (unless we
	-- 	explicitly tag each export which seems a bit of a bore)

    getModuleRn 		`thenRn` \ this_mod ->
    setModuleRn the_mod  $	-- First set the module name of the module being loaded,
				-- so that unqualified occurrences in the interface file
				-- get the right qualifer
    foldlRn loadDecl (iDecls ifaces) rd_decls		`thenRn` \ new_decls ->
    foldlRn loadFixDecl (iFixes ifaces) rd_decls	`thenRn` \ new_fixities ->
    foldlRn loadInstDecl insts rd_insts			`thenRn` \ new_insts ->

    mapRn (loadExport this_mod) exports			`thenRn` \ avails_s ->
    let
	  -- Notice: the 'flavour' of the loaded Module does not have to 
	  --  be the same as the requested Module.
  	 the_mod_hif = moduleIfaceFlavour the_mod
	 mod_details = (the_mod_hif, mod_vers, concat avails_s)

			-- Exclude this module from the "special-inst" modules
	 new_inst_mods = iInstMods ifaces `unionLists` (filter (/= this_mod) rd_inst_mods)

	 new_ifaces = ifaces { iModMap   = addToFM mod_map the_mod mod_details,
			       iDecls    = new_decls,
			       iFixes    = new_fixities,
			       iDefInsts = (new_insts, tycls_names),
			       iInstMods = new_inst_mods  }
    in
    setIfacesRn new_ifaces		`thenRn_`
    returnRn (the_mod, new_ifaces)
    }}

loadExport :: Module -> ExportItem -> RnMG [AvailInfo]
loadExport this_mod (mod, entities)
  | mod == this_mod = returnRn []
	-- If the module exports anything defined in this module, just ignore it.
	-- Reason: otherwise it looks as if there are two local definition sites
	-- for the thing, and an error gets reported.  Easiest thing is just to
	-- filter them out up front. This situation only arises if a module
	-- imports itself, or another module that imported it.  (Necessarily,
	-- this invoves a loop.)  Consequence: if you say
	--	module A where
	--	   import B( AType )
	--	   type AType = ...
	--
	--	module B( AType ) where
	--	   import {-# SOURCE #-} A( AType )
	--
	-- then you'll get a 'B does not export AType' message.  A bit bogus
	-- but it's a bogus thing to do!

  | otherwise
  = setModuleFlavourRn mod `thenRn` \ mod' ->
    mapRn (load_entity mod') entities
  where
    new_name mod occ = newImportedGlobalName mod occ

    load_entity mod (Avail occ)
      =	new_name mod occ	`thenRn` \ name ->
	returnRn (Avail name)
    load_entity mod (AvailTC occ occs)
      =	new_name mod occ	      `thenRn` \ name ->
        mapRn (new_name mod) occs     `thenRn` \ names ->
        returnRn (AvailTC name names)


loadFixDecl :: FixityEnv 
	    -> (Version, RdrNameHsDecl)
	    -> RnMG FixityEnv
loadFixDecl fixity_env (version, FixD (FixitySig rdr_name fixity loc))
  = 	-- Ignore the version; when the fixity changes the version of
	-- its 'host' entity changes, so we don't need a separate version
	-- number for fixities
    newImportedGlobalFromRdrName rdr_name 	`thenRn` \ name ->
    let
	new_fixity_env = addToNameEnv fixity_env name (FixitySig name fixity loc)
    in
    returnRn new_fixity_env

	-- Ignore the other sorts of decl
loadFixDecl fixity_env other_decl = returnRn fixity_env

loadDecl :: DeclsMap
	 -> (Version, RdrNameHsDecl)
	 -> RnMG DeclsMap

loadDecl decls_map (version, decl)
  = getDeclBinders new_name decl	`thenRn` \ maybe_avail ->
    case maybe_avail of {
	Nothing -> returnRn decls_map;	-- No bindings
	Just avail ->

    getDeclSysBinders new_name decl	`thenRn` \ sys_bndrs ->
    let
	main_name     = availName avail
	new_decls_map = foldl add_decl decls_map
				       [ (name, (version,avail,decl',name==main_name)) 
				       | name <- sys_bndrs ++ availNames avail]
	add_decl decls_map (name, stuff)
	  = WARN( name `elemNameEnv` decls_map, ppr name )
	    addToNameEnv decls_map name stuff
    in
    returnRn new_decls_map
    }
  where
    new_name rdr_name loc = newImportedGlobalFromRdrName rdr_name
    {-
      If a signature decl is being loaded, and optIgnoreIfacePragmas is on,
      we toss away unfolding information.

      Also, if the signature is loaded from a module we're importing from source,
      we do the same. This is to avoid situations when compiling a pair of mutually
      recursive modules, peering at unfolding info in the interface file of the other, 
      e.g., you compile A, it looks at B's interface file and may as a result change
      its interface file. Hence, B is recompiled, maybe changing its interface file,
      which will the unfolding info used in A to become invalid. Simple way out is to
      just ignore unfolding info.

      [Jan 99: I junked the second test above.  If we're importing from an hi-boot
       file there isn't going to *be* any pragma info.  Maybe the above comment
       dates from a time where we picked up a .hi file first if it existed?]
    -}
    decl' = 
     case decl of
       SigD (IfaceSig name tp ls loc) | opt_IgnoreIfacePragmas -> 
	    SigD (IfaceSig name tp [] loc)
       _ -> decl

loadInstDecl :: Bag IfaceInst
	     -> RdrNameInstDecl
	     -> RnMG (Bag IfaceInst)
loadInstDecl insts decl@(InstDecl inst_ty binds uprags dfun_name src_loc)
  = 
	-- Find out what type constructors and classes are "gates" for the
	-- instance declaration.  If all these "gates" are slurped in then
	-- we should slurp the instance decl too.
	-- 
	-- We *don't* want to count names in the context part as gates, though.
	-- For example:
	--		instance Foo a => Baz (T a) where ...
	--
	-- Here the gates are Baz and T, but *not* Foo.
    let 
	munged_inst_ty = case inst_ty of
				HsForAllTy tvs cxt ty -> HsForAllTy tvs [] ty
				other		      -> inst_ty
    in
	-- We find the gates by renaming the instance type with in a 
	-- and returning the free variables of the type
    initRnMS emptyRnEnv vanillaInterfaceMode (
        discardOccurrencesRn (rnHsSigType (text "an instance decl") munged_inst_ty)
    )						`thenRn` \ (_, gate_names) ->
    getModuleRn					`thenRn` \ mod_name -> 
    returnRn (((mod_name, decl), gate_names) `consBag` insts)

vanillaInterfaceMode = InterfaceMode Compulsory
\end{code}


%********************************************************
%*							*
\subsection{Loading usage information}
%*							*
%********************************************************

\begin{code}
checkUpToDate :: Module -> RnMG Bool		-- True <=> no need to recompile
checkUpToDate mod_name
  = findAndReadIface doc_str mod_name		`thenRn` \ read_result ->

	-- CHECK WHETHER WE HAVE IT ALREADY
    case read_result of
	Nothing -> 	-- Old interface file not found, so we'd better bail out
		    traceRn (sep [ptext SLIT("Didnt find old iface"), 
				    pprModule mod_name])	`thenRn_`
		    returnRn False

	Just (_, ParsedIface _ usages _ _ _ _) 
		-> 	-- Found it, so now check it
		    checkModUsage usages
  where
	-- Only look in current directory, with suffix .hi
    doc_str = sep [ptext SLIT("need usage info from"), pprModule mod_name]

checkModUsage [] = returnRn True		-- Yes!  Everything is up to date!

checkModUsage ((mod, old_mod_vers, whats_imported) : rest)
  = loadInterface doc_str mod 		`thenRn` \ (mod, ifaces) ->
    let
	maybe_new_mod_vers	  = lookupFM (iModMap ifaces) mod
	Just (_, new_mod_vers, _) = maybe_new_mod_vers
    in
	-- If we can't find a version number for the old module then
	-- bail out saying things aren't up to date
    if not (maybeToBool maybe_new_mod_vers) then
	traceRn (sep [ptext SLIT("Can't find version number for module"), pprModule mod]) `thenRn_`
	returnRn False
    else

	-- If the module version hasn't changed, just move on
    if new_mod_vers == old_mod_vers then
	traceRn (sep [ptext SLIT("Module version unchanged:"), pprModule mod])	`thenRn_`
	checkModUsage rest
    else
    traceRn (sep [ptext SLIT("Module version has changed:"), pprModule mod])	`thenRn_`

	-- Module version changed, so check entities inside

	-- If the usage info wants to say "I imported everything from this module"
	--     it does so by making whats_imported equal to Everything
	-- In that case, we must recompile
    case whats_imported of {
      Everything -> traceRn (ptext SLIT("...and I needed the whole module"))	`thenRn_`
		    returnRn False;		   -- Bale out

      Specifically old_local_vers ->

	-- Non-empty usage list, so check item by item
    checkEntityUsage mod (iDecls ifaces) old_local_vers	`thenRn` \ up_to_date ->
    if up_to_date then
	traceRn (ptext SLIT("...but the bits I use haven't."))	`thenRn_`
	checkModUsage rest	-- This one's ok, so check the rest
    else
	returnRn False		-- This one failed, so just bail out now
    }
  where
    doc_str = sep [ptext SLIT("need version info for"), pprModule mod]


checkEntityUsage mod decls [] 
  = returnRn True	-- Yes!  All up to date!

checkEntityUsage mod decls ((occ_name,old_vers) : rest)
  = newImportedGlobalName mod occ_name 		`thenRn` \ name ->
    case lookupNameEnv decls name of

	Nothing       -> 	-- We used it before, but it ain't there now
			  putDocRn (sep [ptext SLIT("No longer exported:"), ppr name])	`thenRn_`
			  returnRn False

	Just (new_vers,_,_,_) 	-- It's there, but is it up to date?
		| new_vers == old_vers
			-- Up to date, so check the rest
		-> checkEntityUsage mod decls rest

		| otherwise
			-- Out of date, so bale out
		-> putDocRn (sep [ptext SLIT("Out of date:"), ppr name])  `thenRn_`
		   returnRn False
\end{code}


%*********************************************************
%*							*
\subsection{Getting in a declaration}
%*							*
%*********************************************************

\begin{code}
importDecl :: Occurrence -> RnMode -> RnMG (Maybe RdrNameHsDecl)
	-- Returns Nothing for a wired-in or already-slurped decl

importDecl (name, loc) mode
  = checkSlurped name			`thenRn` \ already_slurped ->
    if already_slurped then
--	traceRn (sep [text "Already slurped:", ppr name])	`thenRn_`
	returnRn Nothing	-- Already dealt with
    else
    if isWiredInName name then
	getWiredInDecl name mode
    else 
       getIfacesRn 		`thenRn` \ ifaces ->
       let
         mod = nameModule name
       in
       if mod == iMod ifaces then    -- Don't bring in decls from
	  addWarnRn (importDeclWarn mod name loc) `thenRn_`
--	  pprTrace "importDecl wierdness:" (ppr name) $
	  returnRn Nothing         -- the renamed module's own interface file
			           -- 
       else
       getNonWiredInDecl name loc mode
\end{code}

\begin{code}
getNonWiredInDecl :: Name -> SrcLoc -> RnMode -> RnMG (Maybe RdrNameHsDecl)
getNonWiredInDecl needed_name loc mode
  = traceRn doc_str				`thenRn_`
    loadHomeInterface doc_str needed_name	`thenRn` \ (_, ifaces) ->
    case lookupNameEnv (iDecls ifaces) needed_name of

	-- Special case for data/newtype type declarations
      Just (version, avail, TyClD tycl_decl, _) | isDataDecl tycl_decl
	-> getNonWiredDataDecl needed_name version avail tycl_decl	`thenRn` \ (avail', maybe_decl) ->
	   recordSlurp (Just version) necessity avail'			`thenRn_`
	   returnRn maybe_decl

      Just (version,avail,decl,_)
	-> recordSlurp (Just version) necessity avail	`thenRn_`
	   returnRn (Just decl)

      Nothing -> 	-- Can happen legitimately for "Optional" occurrences
		   case necessity of { 
			Optional -> addWarnRn (getDeclWarn needed_name loc);
			other	 -> addErrRn  (getDeclErr  needed_name loc)
		   }						`thenRn_` 
		   returnRn Nothing
  where
     necessity = modeToNecessity mode
     doc_str = sep [ptext SLIT("need decl for"), ppr needed_name, ptext SLIT("needed at"), ppr loc]
\end{code}

@getWiredInDecl@ maps a wired-in @Name@ to what it makes available.
It behaves exactly as if the wired in decl were actually in an interface file.
Specifically,

  *	if the wired-in name is a data type constructor or a data constructor, 
	it brings in the type constructor and all the data constructors; and
	marks as "occurrences" any free vars of the data con.

  * 	similarly for synonum type constructor

  * 	if the wired-in name is another wired-in Id, it marks as "occurrences"
	the free vars of the Id's type.

  *	it loads the interface file for the wired-in thing for the
	sole purpose of making sure that its instance declarations are available

All this is necessary so that we know all types that are "in play", so
that we know just what instances to bring into scope.
	
\begin{code}
getWiredInDecl name mode
  = setModuleRn mod_name (
	initRnMS emptyRnEnv new_mode get_wired
    )						`thenRn` \ avail ->
    recordSlurp Nothing necessity avail		`thenRn_`

   	-- Force in the home module in case it has instance decls for
	-- the thing we are interested in.
	--
	-- Mini hack 1: no point for non-tycons/class; and if we
	-- do this we find PrelNum trying to import PackedString,
	-- because PrelBase's .hi file mentions PackedString.unpackString
	-- But PackedString.hi isn't built by that point!
	--
	-- Mini hack 2; GHC is guaranteed not to have
	-- instance decls, so it's a waste of time to read it
	--
	-- NB: We *must* look at the availName of the slurped avail, 
	-- not the name passed to getWiredInDecl!  Why?  Because if a data constructor 
	-- or class op is passed to getWiredInDecl we'll pull in the whole data/class
	-- decl, and recordSlurp will record that fact.  But since the data constructor
	-- isn't a tycon/class we won't force in the home module.  And even if the
	-- type constructor/class comes along later, loadDecl will say that it's already
	-- been slurped, so getWiredInDecl won't even be called.  Pretty obscure bug, this was.
    let
	main_name  = availName avail
	main_is_tc = case avail of { AvailTC _ _ -> True; Avail _ -> False }
	mod        = nameModule main_name
	doc_str    = sep [ptext SLIT("need home module for wired in thing"), ppr name]
    in
    (if not main_is_tc || mod == pREL_GHC then
	returnRn ()		
    else
	loadHomeInterface doc_str main_name	`thenRn_`
	returnRn ()
    )						`thenRn_`

    returnRn Nothing		-- No declaration to process further
  where
    necessity = modeToNecessity mode
    new_mode = case mode of 
			InterfaceMode _ -> mode
			SourceMode	-> vanillaInterfaceMode

    get_wired | is_tycon			-- ... a type constructor
	      = get_wired_tycon the_tycon

	      | maybeToBool maybe_data_con 		-- ... a wired-in data constructor
	      = get_wired_tycon (dataConTyCon data_con)

	      | otherwise			-- ... a wired-in non data-constructor
	      = get_wired_id the_id

    mod_name		 = nameModule name
    maybe_wired_in_tycon = maybeWiredInTyConName name
    is_tycon		 = maybeToBool maybe_wired_in_tycon
    maybe_wired_in_id    = maybeWiredInIdName    name
    Just the_tycon	 = maybe_wired_in_tycon
    Just the_id 	 = maybe_wired_in_id
    maybe_data_con	 = isDataConId_maybe the_id
    Just data_con	 = maybe_data_con


get_wired_id id
  = addImplicitOccsRn id_mentions 	`thenRn_`
    returnRn (Avail (getName id))
  where
    id_mentions = nameSetToList (namesOfType ty)
    ty = idType id

get_wired_tycon tycon 
  | isSynTyCon tycon
  = addImplicitOccsRn (nameSetToList mentioned)		`thenRn_`
    returnRn (AvailTC tc_name [tc_name])
  where
    tc_name     = getName tycon
    (tyvars,ty) = getSynTyConDefn tycon
    mentioned   = namesOfType ty `minusNameSet` mkNameSet (map getName tyvars)

get_wired_tycon tycon 
  | otherwise		-- data or newtype
  = addImplicitOccsRn (nameSetToList mentioned)		`thenRn_`
    returnRn (AvailTC tycon_name (tycon_name : map getName data_cons))
  where
    tycon_name = getName tycon
    data_cons  = tyConDataCons tycon
    mentioned  = foldr (unionNameSets . namesOfType . dataConType) emptyNameSet data_cons
\end{code}


    
%*********************************************************
%*							*
\subsection{Getting what a module exports}
%*							*
%*********************************************************

\begin{code}
getInterfaceExports :: Module -> RnMG (Module, Avails)
getInterfaceExports mod
  = loadInterface doc_str mod	`thenRn` \ (mod, ifaces) ->
    case lookupFM (iModMap ifaces) mod of
	Nothing ->	-- Not there; it must be that the interface file wasn't found;
			-- the error will have been reported already.
			-- (Actually loadInterface should put the empty export env in there
			--  anyway, but this does no harm.)
		      returnRn (mod, [])

	Just (_, _, avails) -> returnRn (mod, avails)
  where
    doc_str = sep [pprModule mod, ptext SLIT("is directly imported")]
\end{code}


%*********************************************************
%*							*
\subsection{Data type declarations are handled specially}
%*							*
%*********************************************************

Data type declarations get special treatment.  If we import a data type decl
with all its constructors, we end up importing all the types mentioned in 
the constructors' signatures, and hence {\em their} data type decls, and so on.
In effect, we get the transitive closure of data type decls.  Worse, this drags
in tons on instance decls, and their unfoldings, and so on.

If only the type constructor is mentioned, then all this is a waste of time.
If any of the data constructors are mentioned then we really have to 
drag in the whole declaration.

So when we import the type constructor for a @data@ or @newtype@ decl, we
put it in the "deferred data/newtype decl" pile in Ifaces.  Right at the end
we slurp these decls, if they havn't already been dragged in by an occurrence
of a constructor.

\begin{code}
getNonWiredDataDecl needed_name 
		    version
	 	    avail@(AvailTC tycon_name _) 
		    ty_decl@(TyData new_or_data context tycon tyvars condecls derivings pragmas src_loc)
  |  null condecls ||
	-- HACK ALERT!  If the data type is abstract then it must from a 
	-- hand-written hi-boot file.  We put it in the deferred pile unconditionally,
	-- because we don't want to read it in, and then later find a decl for a constructor
	-- from that type, read the real interface file, and read in the full data type
	-- decl again!!!  

     (needed_name == tycon_name
     && opt_PruneTyDecls
        -- don't prune newtypes, as the code generator may
	-- want to peer inside a newtype type constructor
	-- (ClosureInfo.fun_result_ty is the culprit.)
     && not (new_or_data == NewType)
     && not (nameUnique needed_name `elem` cCallishTyKeys))
	-- Hack!  Don't prune these tycons whose constructors
	-- the desugarer must be able to see when desugaring
	-- a CCall.  Ugh!

  = 	-- Need the type constructor; so put it in the deferred set for now
    getIfacesRn 		`thenRn` \ ifaces ->
    let
	deferred_data_decls = iDefData ifaces
	new_ifaces          = ifaces {iDefData = new_deferred_data_decls}

	no_constr_ty_decl       = TyData new_or_data [] tycon tyvars [] derivings pragmas src_loc
	new_deferred_data_decls = addToNameEnv deferred_data_decls tycon_name 
					       (nameModule tycon_name, no_constr_ty_decl)
		-- Nota bene: we nuke both the constructors and the context in the deferred decl.
		-- If we don't nuke the context then renaming the deferred data decls can give
		-- new unresolved names (for the classes).  This could be handled, but there's
		-- no point.  If the data type is completely abstract then we aren't interested
		-- its context.
    in
    setIfacesRn new_ifaces	`thenRn_`
    returnRn (AvailTC tycon_name [tycon_name], Nothing)

  | otherwise
  = 	-- Need a data constructor, so delete the data decl from the deferred set if it's there
    getIfacesRn 		`thenRn` \ ifaces ->
    let
	deferred_data_decls = iDefData ifaces
	new_ifaces          = ifaces {iDefData = new_deferred_data_decls}

	new_deferred_data_decls = delFromNameEnv deferred_data_decls tycon_name
    in
    setIfacesRn new_ifaces	`thenRn_`
    returnRn (avail, Just (TyClD ty_decl))
\end{code}

\begin{code}
getDeferredDataDecls :: RnMG [(Module, RdrNameTyClDecl)]
getDeferredDataDecls 
  = getIfacesRn 		`thenRn` \ ifaces ->
    let
	deferred_list = nameEnvElts (iDefData ifaces)
	trace_msg = hang (text "Slurping abstract data/newtype decls for: ")
			4 (ppr (map fst deferred_list))
    in
    traceRn trace_msg			`thenRn_`
    returnRn deferred_list
\end{code}


%*********************************************************
%*							*
\subsection{Instance declarations are handled specially}
%*							*
%*********************************************************

\begin{code}
getImportedInstDecls :: RnMG [(Module,RdrNameInstDecl)]
getImportedInstDecls
  = 	-- First load any special-instance modules that aren't aready loaded
    getSpecialInstModules 			`thenRn` \ inst_mods ->
    mapRn_ load_it inst_mods			`thenRn_`

	-- Now we're ready to grab the instance declarations
	-- Find the un-gated ones and return them, 
	-- removing them from the bag kept in Ifaces
    getIfacesRn 	`thenRn` \ ifaces ->
    let
	(insts, tycls_names) = iDefInsts ifaces

		-- An instance decl is ungated if all its gates have been slurped
        select_ungated :: IfaceInst					-- A gated inst decl

		       -> ([(Module, RdrNameInstDecl)], [IfaceInst])	-- Accumulator

		       -> ([(Module, RdrNameInstDecl)], 		-- The ungated ones
			   [IfaceInst]) 				-- Still gated, but with
									-- depeleted gates
	select_ungated (decl,gates) (ungated_decls, gated_decls)
	  | isEmptyNameSet remaining_gates
	  = (decl : ungated_decls, gated_decls)
	  | otherwise
	  = (ungated_decls, (decl, remaining_gates) : gated_decls)
	  where
	    remaining_gates = gates `minusNameSet` tycls_names

	(un_gated_insts, still_gated_insts) = foldrBag select_ungated ([], []) insts
	
	new_ifaces = ifaces {iDefInsts = (listToBag still_gated_insts, tycls_names)}
				-- NB: don't throw away tycls_names;
				-- we may comre across more instance decls
    in
    traceRn (sep [text "getInstDecls:", fsep (map ppr (nameSetToList tycls_names))])	`thenRn_`
    setIfacesRn new_ifaces	`thenRn_`
    returnRn un_gated_insts
  where
    load_it mod = loadInterface (doc_str mod) mod
    doc_str mod = sep [pprModule mod, ptext SLIT("is a special-instance module")]


getSpecialInstModules :: RnMG [Module]
getSpecialInstModules 
  = getIfacesRn						`thenRn` \ ifaces ->
    returnRn (iInstMods ifaces)

getImportedFixities :: GlobalRdrEnv -> RnMG FixityEnv
	-- Get all imported fixities
	-- We first make sure that all the home modules
	-- of all in-scope variables are loaded.
getImportedFixities gbl_env
  = let
	home_modules = [ nameModule name | names <- rdrEnvElts gbl_env,
					   name <- names,
					   not (isLocallyDefined name)
		       ]
    in
    mapRn_ load (nub home_modules)	`thenRn_`

	-- Now we can snaffle the fixity env
    getIfacesRn						`thenRn` \ ifaces ->
    returnRn (iFixes ifaces)
  where
    load mod = loadInterface doc_str mod
	     where
	       doc_str = ptext SLIT("Need fixities from") <+> ppr mod
\end{code}


%*********************************************************
%*							*
\subsection{Keeping track of what we've slurped, and version numbers}
%*							*
%*********************************************************

getImportVersions figures out what the "usage information" for this moudule is;
that is, what it must record in its interface file as the things it uses.
It records:
	- anything reachable from its body code
	- any module exported with a "module Foo".

Why the latter?  Because if Foo changes then this module's export list
will change, so we must recompile this module at least as far as
making a new interface file --- but in practice that means complete
recompilation.

What about this? 
	module A( f, g ) where		module B( f ) where
	  import B( f )			  f = h 3
	  g = ...			  h = ...

Should we record B.f in A's usages?  In fact we don't.  Certainly, if
anything about B.f changes than anyone who imports A should be recompiled;
they'll get an early exit if they don't use B.f.  However, even if B.f
doesn't change at all, B.h may do so, and this change may not be reflected
in f's version number.  So there are two things going on when compiling module A:

1.  Are A.o and A.hi correct?  Then we can bale out early.
2.  Should modules that import A be recompiled?

For (1) it is slightly harmful to record B.f in A's usages, because a change in
B.f's version will provoke full recompilation of A, producing an identical A.o,
and A.hi differing only in its usage-version of B.f (which isn't used by any importer).

For (2), because of the tricky B.h question above, we ensure that A.hi is touched
(even if identical to its previous version) if A's recompilation was triggered by
an imported .hi file date change.  Given that, there's no need to record B.f in
A's usages.

On the other hand, if A exports "module B" then we *do* count module B among
A's usages, because we must recompile A to ensure that A.hi changes appropriately.

\begin{code}
getImportVersions :: Module			-- Name of this module
		  -> Maybe [IE any]		-- Export list for this module
		  -> RnMG (VersionInfo Name)	-- Version info for these names

getImportVersions this_mod exports
  = getIfacesRn					`thenRn` \ ifaces ->
    let
	mod_map   = iModMap ifaces
	imp_names = iVSlurp ifaces

	-- mv_map groups together all the things imported from a particular module.
	mv_map, mv_map_mod :: FiniteMap Module (WhatsImported Name)

	mv_map_mod = foldl add_mod emptyFM export_mods
		-- mv_map_mod records all the modules that have a "module M"
		-- in this module's export list with an "Everything" 

	mv_map = foldl add_mv mv_map_mod imp_names
		-- mv_map adds the version numbers of things exported individually

	mk_version_info (mod, local_versions)
	   = case lookupFM mod_map mod of
		Just (hif, version, _) -> (mod, version, local_versions)
    in
    returnRn (map mk_version_info (fmToList mv_map))
  where
     export_mods = case exports of
			Nothing -> []
			Just es -> [mod | IEModuleContents mod <- es, mod /= this_mod]

     add_mv mv_map v@(name, version) 
      = addToFM_C add_item mv_map mod (Specifically [v]) 
	where
	 mod = nameModule name

         add_item Everything        _ = Everything
         add_item (Specifically xs) _ = Specifically (v:xs)

     add_mod mv_map mod = addToFM mv_map mod Everything
\end{code}

\begin{code}
checkSlurped name
  = getIfacesRn 	`thenRn` \ ifaces ->
    returnRn (name `elemNameSet` iSlurp ifaces)

getSlurpedNames :: RnMG NameSet
getSlurpedNames
  = getIfacesRn 	`thenRn` \ ifaces ->
    returnRn (iSlurp ifaces)

recordSlurp maybe_version necessity avail
  = {- traceRn (hsep [text "Record slurp:", pprAvail avail, 
					-- NB PprForDebug prints export flag, which is too
					-- strict; it's a knot-tied thing in RnNames
		  case necessity of {Compulsory -> text "comp"; Optional -> text "opt" } ])	`thenRn_` 
    -}
    getIfacesRn 	`thenRn` \ ifaces ->
    let
	Ifaces { iSlurp    = slurped_names,
		 iVSlurp   = imp_names,
		 iDefInsts = (insts, tycls_names) } = ifaces

	new_slurped_names = addAvailToNameSet slurped_names avail

	new_imp_names = case maybe_version of
			   Just version	-> (availName avail, version) : imp_names
			   Nothing      -> imp_names

		-- Add to the names that will let in instance declarations;
		-- but only (a) if it's a type/class
		--	    (b) if it's compulsory (unless the test flag opt_PruneInstDecls is off)
	new_tycls_names = case avail of
				AvailTC tc _  | not opt_PruneInstDecls || 
						case necessity of {Optional -> False; Compulsory -> True }
					      -> tycls_names `addOneToNameSet` tc
				otherwise     -> tycls_names

	new_ifaces = ifaces { iSlurp    = new_slurped_names,
			      iVSlurp   = new_imp_names,
			      iDefInsts = (insts, new_tycls_names) }
    in
    setIfacesRn new_ifaces
\end{code}


%*********************************************************
%*							*
\subsection{Getting binders out of a declaration}
%*							*
%*********************************************************

@getDeclBinders@ returns the names for a @RdrNameHsDecl@.
It's used for both source code (from @availsFromDecl@) and interface files
(from @loadDecl@).

It doesn't deal with source-code specific things: ValD, DefD.  They
are handled by the sourc-code specific stuff in RnNames.

\begin{code}
getDeclBinders :: (RdrName -> SrcLoc -> RnMG Name)	-- New-name function
		-> RdrNameHsDecl
		-> RnMG (Maybe AvailInfo)

getDeclBinders new_name (TyClD (TyData _ _ tycon _ condecls _ _ src_loc))
  = new_name tycon src_loc			`thenRn` \ tycon_name ->
    getConFieldNames new_name condecls		`thenRn` \ sub_names ->
    returnRn (Just (AvailTC tycon_name (tycon_name : nub sub_names)))
	-- The "nub" is because getConFieldNames can legitimately return duplicates,
	-- when a record declaration has the same field in multiple constructors

getDeclBinders new_name (TyClD (TySynonym tycon _ _ src_loc))
  = new_name tycon src_loc		`thenRn` \ tycon_name ->
    returnRn (Just (AvailTC tycon_name [tycon_name]))

getDeclBinders new_name (TyClD (ClassDecl _ cname _ sigs _ _ tname dname src_loc))
  = new_name cname src_loc			`thenRn` \ class_name ->

	-- Record the names for the class ops
    let
	-- just want class-op sigs
	op_sigs = filter isClassOpSig sigs
    in
    mapRn (getClassOpNames new_name) op_sigs	`thenRn` \ sub_names ->

    returnRn (Just (AvailTC class_name (class_name : sub_names)))

getDeclBinders new_name (SigD (IfaceSig var ty prags src_loc))
  = new_name var src_loc			`thenRn` \ var_name ->
    returnRn (Just (Avail var_name))

getDeclBinders new_name (FixD _)  = returnRn Nothing
getDeclBinders new_name (ForD _)  = returnRn Nothing
getDeclBinders new_name (DefD _)  = returnRn Nothing
getDeclBinders new_name (InstD _) = returnRn Nothing

----------------
getConFieldNames new_name (ConDecl con _ _ (RecCon fielddecls) src_loc : rest)
  = mapRn (\n -> new_name n src_loc) (con:fields)	`thenRn` \ cfs ->
    getConFieldNames new_name rest			`thenRn` \ ns  -> 
    returnRn (cfs ++ ns)
  where
    fields = concat (map fst fielddecls)

getConFieldNames new_name (ConDecl con _ _ condecl src_loc : rest)
  = new_name con src_loc		`thenRn` \ n ->
    (case condecl of
      NewCon _ (Just f) -> 
        new_name f src_loc `thenRn` \ new_f ->
	returnRn [n,new_f]
      _ -> returnRn [n])		`thenRn` \ nn ->
    getConFieldNames new_name rest	`thenRn` \ ns -> 
    returnRn (nn ++ ns)

getConFieldNames new_name [] = returnRn []

getClassOpNames new_name (ClassOpSig op _ _ src_loc) = new_name op src_loc
\end{code}

@getDeclSysBinders@ gets the implicit binders introduced by a decl.
A the moment that's just the tycon and datacon that come with a class decl.
They aren'te returned by getDeclBinders because they aren't in scope;
but they *should* be put into the DeclsMap of this module.

\begin{code}
getDeclSysBinders new_name (TyClD (ClassDecl _ cname _ sigs _ _ tname dname src_loc))
  = new_name dname src_loc		        `thenRn` \ datacon_name ->
    new_name tname src_loc		        `thenRn` \ tycon_name ->
    returnRn [tycon_name, datacon_name]

getDeclSysBinders new_name other_decl
  = returnRn []
\end{code}

%*********************************************************
%*							*
\subsection{Reading an interface file}
%*							*
%*********************************************************

\begin{code}
findAndReadIface :: SDoc -> Module -> RnMG (Maybe (Module, ParsedIface))
	-- Nothing <=> file not found, or unreadable, or illegible
	-- Just x  <=> successfully found and parsed 

findAndReadIface doc_str mod_name
  = traceRn trace_msg			`thenRn_`
      -- we keep two maps for interface files,
      -- one for 'normal' ones, the other for .hi-boot files,
      -- hence the need to signal which kind we're interested.
    getModuleHiMap from_hi_boot		`thenRn` \ himap ->
    case (lookupFM himap (moduleUserString mod_name)) of
         -- Found the file
       Just fpath -> readIface mod_name fpath
       Nothing    -> traceRn (ptext SLIT("...failed"))	`thenRn_`
	             returnRn Nothing
  where
    hif		 = moduleIfaceFlavour mod_name
    from_hi_boot = bootFlavour hif

    trace_msg = sep [hsep [ptext SLIT("Reading"), 
			   if from_hi_boot then ptext SLIT("[boot]") else empty,
			   ptext SLIT("interface for"), 
			   pprModule mod_name <> semi],
		     nest 4 (ptext SLIT("reason:") <+> doc_str)]
\end{code}

@readIface@ tries just the one file.

\begin{code}
readIface :: Module -> (String, Bool) -> RnMG (Maybe (Module, ParsedIface))
	-- Nothing <=> file not found, or unreadable, or illegible
	-- Just x  <=> successfully found and parsed 
readIface requested_mod (file_path, is_dll)
  = ioToRnMG (hGetStringBuffer file_path)       `thenRn` \ read_result ->
    case read_result of
	Right contents	  -> 
             case parseIface contents (mkSrcLoc (mkFastString file_path) 1) of
	          Failed err                    -> failWithRn Nothing err 
		  Succeeded (PIface mod_nm iface) ->
			    (if mod_nm /=  moduleFS requested_mod then
			        addWarnRn (hsep [ ptext SLIT("Something is amiss; requested module name")
				                , pprModule requested_mod
				                , ptext SLIT("differs from name found in the interface file ")
						, pprEncodedFS mod_nm
						])
			     else
			        returnRn ())	    `thenRn_`
			    let
			     the_mod 
			       | is_dll    = mkDynamicModule requested_mod
			       | otherwise = requested_mod
			    in
			    if opt_D_show_rn_imports then
			       putDocRn (hcat[ptext SLIT("Read module "), pprEncodedFS mod_nm,
					      ptext SLIT(" from "), text file_path]) `thenRn_`
			       returnRn (Just (the_mod, iface))
			    else
			       returnRn (Just (the_mod, iface))

        Left err
	  | isDoesNotExistError err -> returnRn Nothing
	  | otherwise               -> failWithRn Nothing (cannaeReadFile file_path err)

\end{code}

%*********************************************************
%*						 	 *
\subsection{Utils}
%*							 *
%*********************************************************

@mkSearchPath@ takes a string consisting of a colon-separated list
of directories and corresponding suffixes, and turns it into a list
of (directory, suffix) pairs.  For example:

\begin{verbatim}
 mkSearchPath "foo%.hi:.%.p_hi:baz%.mc_hi"
   = [("foo",".hi"),( ".", ".p_hi"), ("baz",".mc_hi")]
\begin{verbatim}

\begin{code}
mkSearchPath :: Maybe String -> SearchPath
mkSearchPath Nothing = [(".",".hi")]  -- ToDo: default should be to look in
				      -- the directory the module we're compiling
				      -- lives.
mkSearchPath (Just s) = go s
  where
    go "" = []
    go s  = 
      case span (/= '%') s of
       (dir,'%':rs) ->
         case span (/= ':') rs of
          (hisuf,_:rest) -> (dir,hisuf):go rest
          (hisuf,[])     -> [(dir,hisuf)]
\end{code}

%*********************************************************
%*						 	 *
\subsection{Errors}
%*							 *
%*********************************************************

\begin{code}
noIfaceErr filename
  = hcat [ptext SLIT("Could not find valid interface file "), 
          quotes (pprModule filename)]

cannaeReadFile file err
  = hcat [ptext SLIT("Failed in reading file: "), 
          text file, 
	  ptext SLIT("; error="), 
	  text (show err)]

getDeclErr name loc
  = sep [ptext SLIT("Failed to find interface decl for") <+> quotes (ppr name), 
	 ptext SLIT("needed at") <+> ppr loc]

getDeclWarn name loc
  = sep [ptext SLIT("Failed to find (optional) interface decl for") <+> quotes (ppr name),
	 ptext SLIT("desired at") <+> ppr loc]

importDeclWarn mod name loc
  = sep [ptext SLIT("Compiler tried to import decl from interface file with same name as module."), 
	 ptext SLIT("(possible cause: module name clashes with interface file already in scope.)")
	] $$
    hsep [ptext SLIT("Interface:"), quotes (pprModule mod), comma, ptext SLIT("name:"), quotes (ppr name), 
	  comma, ptext SLIT("desired at:"), ppr loc
         ]

\end{code}
