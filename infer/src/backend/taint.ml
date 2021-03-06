(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

module L = Logging

open PatternMatch

(* list of sources that return a tainted value *)
let sources = [
  (* for testing only *)
  {
    classname = "com.facebook.infer.models.InferTaint";
    method_name = "inferSecretSource";
    ret_type = "java.lang.Object";
    params = [];
    is_static = true;
    language = Config.Java;
  };
  {
    classname = "com.facebook.infer.models.InferTaint";
    method_name = "inferSecretSourceUndefined";
    ret_type = "java.lang.Object";
    params = [];
    is_static = true;
    language = Config.Java
  };
  (* actual specs *)
  {
    classname = "android.content.SharedPreferences";
    method_name = "getString";
    ret_type = "java.lang.String";
    params = ["java.lang.String"; "java.lang.String"];
    is_static = false;
    language = Config.Java
  };
] @ FbTaint.sources

(* list of (sensitive sinks, zero-indexed numbers of parameters that should not be tainted). note:
   index 0 means "the first non-this/self argument"; we currently don't have a way to say "this/self
   should not be tainted" with this form of specification *)
let sinks = [
  (* for testing only *)
  ({
    classname = "com.facebook.infer.models.InferTaint";
    method_name = "inferSensitiveSink";
    ret_type = "void";
    params = ["java.lang.Object"];
    is_static = true;
    language = Config.Java
  }, [0]);
  ({
    classname = "com.facebook.infer.models.InferTaint";
    method_name = "inferSensitiveSinkUndefined";
    ret_type = "void";
    params = ["java.lang.Object"];
    is_static = true;
    language = Config.Java
  }, [0]);
  (* actual specs *)
  ({
    classname = "android.util.Log";
    method_name = "d";
    ret_type = "int";
    params = ["java.lang.String"; "java.lang.String"];
    is_static = true;
    language = Config.Java
  }, [0;1]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openInputStream";
    ret_type = "java.io.InputStream";
    params = ["android.net.Uri"];
    is_static = false;
    language = Config.Java;
  }, [1]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openOutputStream";
    ret_type = "java.io.OutputStream";
    params = ["android.net.Uri"];
    is_static = false;
    language = Config.Java;
  }, [0]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openOutputStream";
    ret_type = "java.io.OutputStream";
    params = ["android.net.Uri"; "java.lang.String"];
    is_static = false;
    language = Config.Java;
  }, [0]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openAssetFileDescriptor";
    ret_type = "android.content.res.AssetFileDescriptor";
    params = ["android.net.Uri"; "java.lang.String"];
    is_static = false;
    language = Config.Java;
  }, [0]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openAssetFileDescriptor";
    ret_type = "android.content.res.AssetFileDescriptor";
    params = ["android.net.Uri"; "java.lang.String"; "android.os.CancellationSignal"];
    is_static = false;
    language = Config.Java;
  }, [0]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openFileDescriptor";
    ret_type = "android.os.ParcelFileDescriptor";
    params = ["android.net.Uri"; "java.lang.String"; "android.os.CancellationSignal"];
    is_static = false;
    language = Config.Java;
  }, [0]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openFileDescriptor";
    ret_type = "android.os.ParcelFileDescriptor";
    params = ["android.net.Uri"; "java.lang.String"];
    is_static = false;
    language = Config.Java;
  }, [0]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openTypedAssetFileDescriptor";
    ret_type = "android.content.res.AssetFileDescriptor";
    params = ["android.net.Uri"; "java.lang.String"; "android.os.Bundle";
              "android.os.CancellationSignal"];
    is_static = false;
    language = Config.Java;
  }, [0]);
  ({
    classname = "android.content.ContentResolver";
    method_name = "openTypedAssetFileDescriptor";
    ret_type = "android.content.res.AssetFileDescriptor";
    params = ["android.net.Uri"; "java.lang.String"; "android.os.Bundle"];
    is_static = false;
    language = Config.Java;
  }, [0]);

  (*  ==== iOS for testing only ==== *)
  ({
    classname = "ExampleViewController";
    method_name = "loadURL:trackingCodes:";
    ret_type = "void";
    params = [];
    is_static = false;
    language = Config.C_CPP
  }, [1]); (* it's instance method *)
] @ FbTaint.sinks

let functions_with_tainted_params = [
  (*  ==== iOS for testing only ==== *)
  ({
    classname = "ExampleDelegate";
    method_name = "application:openURL:sourceApplication:annotation:";
    ret_type = "BOOL";
    params = [];
    is_static = false; (* it's instance method *)
    language = Config.C_CPP
  }, [2]);

  (* actual specs *)
  ({ (* This method is a source in iOS as it get as parameter
        a non trusted URL (openURL). The method the passes
        it around and this URL may arrive unsanitized to
        loadURL:trackingCodes: of FBWebViewController
        which uses the URL. *)
    classname = "AppDelegate";
    method_name = "application:openURL:sourceApplication:annotation:";
    ret_type = "BOOL";
    params = [];
    is_static = false; (* it's instance method *)
    language = Config.C_CPP
  }, [2]);
] @ FbTaint.functions_with_tainted_params

(* turn string specificiation of Java method into a procname *)
let java_method_to_procname java_method =
  Procname.Java
    (Procname.java
       (Procname.split_classname java_method.classname)
       (Some (Procname.split_classname java_method.ret_type))
       java_method.method_name
       (IList.map Procname.split_classname java_method.params)
       (if java_method.is_static then Procname.Static else Procname.Non_Static))

(* turn string specificiation of an objc method into a procname *)
let objc_method_to_procname objc_method =
  let method_kind = Procname.objc_method_kind_of_bool (not objc_method.is_static) in
  let mangled = Procname.mangled_of_objc_method_kind method_kind in
  Procname.ObjC_Cpp
    (Procname.objc_cpp objc_method.classname objc_method.method_name mangled)

let method_str_to_pname method_str =
  match method_str.language with
  | Config.C_CPP ->
      objc_method_to_procname method_str
  | Config.Java ->
      java_method_to_procname method_str

let sources =
  IList.map method_str_to_pname sources

let mk_pname_param_num methods =
  IList.map
    (fun (mname, param_num) -> method_str_to_pname mname, param_num)
    methods

let taint_sinks =
  mk_pname_param_num sinks

let func_with_tainted_params =
  mk_pname_param_num functions_with_tainted_params

let attrs_opt_get_annots = function
  | Some attrs -> attrs.ProcAttributes.method_annotation
  | None -> Sil.method_annotation_empty

(** returns true if [callee_pname] returns a tainted value *)
let returns_tainted callee_pname callee_attrs_opt =
  IList.exists (fun pname -> Procname.equal pname callee_pname) sources ||
  let ret_annot, _ = attrs_opt_get_annots callee_attrs_opt in
  Annotations.ia_is_privacy_source ret_annot

let find_callee methods callee_pname =
  try
    snd (IList.find (fun (pname, _) -> Procname.equal pname callee_pname) methods)
  with Not_found -> []

(** returns list of zero-indexed argument numbers of [callee_pname] that may be tainted *)
let accepts_sensitive_params callee_pname callee_attrs_opt =
  match find_callee taint_sinks callee_pname with
  | [] ->
      let _, param_annots = attrs_opt_get_annots callee_attrs_opt in
      let offset = if Procname.java_is_static callee_pname then 0 else 1 in
      IList.mapi (fun param_num attr  -> (param_num + offset, attr)) param_annots
      |> IList.filter (fun (_, attr) -> Annotations.ia_is_privacy_sink attr)
      |> IList.map fst
  | tainted_params -> tainted_params

(** returns list of zero-indexed parameter numbers of [callee_pname] that should be
    considered tainted during symbolic execution *)
let tainted_params callee_pname =
  find_callee func_with_tainted_params callee_pname

let has_taint_annotation fieldname struct_typ =
  let fld_has_taint_annot (fname, _, annot) =
    Ident.fieldname_equal fieldname fname &&
    Annotations.ia_is_privacy_source annot in
  IList.exists fld_has_taint_annot struct_typ.Sil.instance_fields ||
  IList.exists fld_has_taint_annot struct_typ.Sil.static_fields
