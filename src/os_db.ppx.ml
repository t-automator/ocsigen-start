(* Ocsigen-start
 * http://www.ocsigen.org/ocsigen-start
 *
 * Copyright (C) Université Paris Diderot, CNRS, INRIA, Be Sport.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

include Os_core_db

exception No_such_resource
exception Wrong_password
exception Password_not_set
exception No_such_user
exception Empty_password
exception Main_email_removal_attempt
exception Account_not_activated

let (>>=) = Lwt.bind

module Lwt_thread = struct
  include Lwt
  let close_in = Lwt_io.close
  let really_input = Lwt_io.read_into_exactly
  let input_binary_int = Lwt_io.BE.read_int
  let input_char = Lwt_io.read_char
  let output_string = Lwt_io.write
  let output_binary_int = Lwt_io.BE.write_int
  let output_char = Lwt_io.write_char
  let flush = Lwt_io.flush
  let open_connection x = Lwt_io.open_connection x
  type out_channel = Lwt_io.output_channel
  type in_channel = Lwt_io.input_channel
end

module Lwt_Query_ = Query.Make_with_Db(Lwt_thread)(PGOCaml)

let view_one rq =
  try List.hd rq
  with Failure _ -> raise No_such_resource

let view_one_lwt rq =
  try_lwt
    lwt rq = rq in
    Lwt.return (view_one rq)
  with No_such_resource -> Lwt.fail No_such_resource

let view_one_opt rq =
  try_lwt
    lwt rq = rq in
    Lwt.return_some ((view_one rq))
  with No_such_resource -> Lwt.return_none

module Lwt_Query = struct
  include Lwt_Query_
  let view_one dbh rq =
    try_lwt
      view_one dbh rq
    with Failure _ -> Lwt.fail No_such_resource
end


(*****************************************************************************)
(* tables, for Macaque *)
let os_users_userid_seq = <:sequence< bigserial "ocsigen_start.users_userid_seq" >>

let os_users_table =
  <:table< ocsigen_start.users (
       userid bigint NOT NULL DEFAULT(nextval $os_users_userid_seq$),
       firstname text NOT NULL,
       lastname text NOT NULL,
       main_email citext,
       password text,
       avatar text,
       language text
          ) >>

let os_emails_table =
  <:table< ocsigen_start.emails (
       email citext NOT NULL,
       userid bigint NOT NULL,
       validated boolean NOT NULL DEFAULT(false)
           ) >>

let os_phones_table =
  <:table< ocsigen_start.phones (
       number citext NOT NULL,
       userid bigint NOT NULL
           ) >>

let os_action_link_table :
  (< .. >,
   < creationdate : < nul : Sql.non_nullable; .. > Sql.t > Sql.writable)
    Sql.view =
  <:table< ocsigen_start.activation (
       activationkey text NOT NULL,
       userid bigint NOT NULL,
       email citext NOT NULL,
       autoconnect boolean NOT NULL,
       validity bigint NOT NULL,
       action text NOT NULL,
       data text NOT NULL,
       creationdate timestamptz NOT NULL DEFAULT(current_timestamp ())
           ) >>

let os_groups_groupid_seq =
  <:sequence< bigserial "ocsigen_start.groups_groupid_seq" >>

let os_groups_table =
  <:table< ocsigen_start.groups (
       groupid bigint NOT NULL DEFAULT(nextval $os_groups_groupid_seq$),
       name text NOT NULL,
       description text
          ) >>

let os_user_groups_table =
  <:table< ocsigen_start.user_groups (
       userid bigint NOT NULL,
       groupid bigint NOT NULL
          ) >>

let os_preregister_table =
  <:table< ocsigen_start.preregister (
       email citext NOT NULL
          ) >>



(*****************************************************************************)

module Utils = struct

  let as_sql_string v = <:value< $string:v$>>

  let run_query q = full_transaction_block (fun dbh ->
    Lwt_Query.query dbh q)

  let run_view ?dbh q =
    let f dbh = Lwt_Query.view dbh q in
    match dbh with
    | Some dbh ->
      f dbh
    | None ->
      full_transaction_block f

  let run_view_opt q = full_transaction_block (fun dbh ->
    Lwt_Query.view_opt dbh q)

  let one f ~success ~fail q =
    f q >>= function
    | r::_ -> success r
    | _ -> fail

  let password_of d = <:value< $d$.password>>

  let avatar_of d = <:value< $d$.avatar>>

  let language_of d = <:value< $d$.language>>

  let tupple_of_user_sql u =
    u#!userid, u#!firstname, u#!lastname, u#?avatar, u#?password <> None, u#?language

end
open Utils

let pwd_crypt_ref = ref
    ((fun password -> Bcrypt.string_of_hash (Bcrypt.hash password)),
     (fun _ password1 password2 ->
        Bcrypt.verify password1 (Bcrypt.hash_of_string password2)))

module Email = struct

  let available email = one run_query
      ~success:(fun _ -> Lwt.return_false)
      ~fail:Lwt.return_true
      <:select< row
                | row in $os_emails_table$; row2 in $os_users_table$;
                row.email = $string:email$;
                row2.userid = row.userid
      >>

end

module User = struct

  exception Invalid_action_link_key of Os_types.User.id

  let userid_of_email email = one run_view
    ~success:(fun u -> Lwt.return u#!userid)
    ~fail:(Lwt.fail No_such_resource)
    <:view< { t1.userid }
     | t1 in $os_users_table$;
       t2 in $os_emails_table$;
       t1.userid = t2.userid;
       t2.email = $string:email$
    >>

  let is_registered email =
    try_lwt
      lwt _ = userid_of_email email in
      Lwt.return_true
    with No_such_resource -> Lwt.return_false

  let is_email_validated userid email = one run_query
    ~success:(fun _ -> Lwt.return_true)
    ~fail:Lwt.return_false
    <:select< row |
      row in $os_emails_table$;
      row.userid = $int64:userid$;
      row.email  = $string:email$;
      row.validated
    >>

  let set_email_validated userid email = run_query
    <:update< e in $os_emails_table$ := {validated = $bool:true$}
     | e.userid = $int64:userid$;
       e.email  = $string:email$
    >>

  let add_actionlinkkey ?(autoconnect=false)
      ?(action=`AccountActivation) ?(data="") ?(validity=1L)
      ~act_key ~userid ~email () =
    let action = match action with
      | `AccountActivation -> "activation"
      | `PasswordReset -> "passwordreset"
      | `Custom s -> s in
    run_query
     <:insert< $os_action_link_table$ :=
      { userid = $int64:userid$;
        email  = $string:email$;
        action = $string:action$;
        autoconnect = $bool:autoconnect$;
        data   = $string:data$;
        validity = $int64:validity$;
        activationkey  = $string:act_key$;
        creationdate   = os_action_link_table?creationdate }
      >>


  let add_preregister email = run_query
  <:insert< $os_preregister_table$ := { email = $string:email$ } >>

  let remove_preregister email = run_query
    <:delete< r in $os_preregister_table$ | r.email = $string:email$ >>

  let is_preregistered email = one run_view
    ~success:(fun _ -> Lwt.return_true)
    ~fail:Lwt.return_false
    <:view< { r.email }
     | r in $os_preregister_table$;
       r.email = $string:email$ >>

  let all ?(limit = 10L) () = run_query
    <:select< { email = a.email } limit $int64:limit$
    | a in $os_preregister_table$;
    >> >>= fun l ->
    Lwt.return (List.map (fun a -> a#!email) l)

  let create ?password ?avatar ?language ?email ~firstname ~lastname () =
    if password = Some "" then Lwt.fail_with "empty password"
    else
      full_transaction_block (fun dbh ->
        let password_o = Eliom_lib.Option.map (fun p ->
          as_sql_string @@ fst !pwd_crypt_ref p) password
        in
        let avatar_o = Eliom_lib.Option.map as_sql_string avatar in
        let language_o = Eliom_lib.Option.map as_sql_string language in
        let email_o = Eliom_lib.Option.map as_sql_string email in
        lwt () = Lwt_Query.query dbh
          <:insert< $os_users_table$ :=
           { userid     = os_users_table?userid;
             firstname  = $string:firstname$;
             lastname   = $string:lastname$;
             main_email = of_option $email_o$;
             password   = of_option $password_o$;
             avatar     = of_option $avatar_o$;
             language   = of_option $language_o$
            } >>
        in
        lwt userid = Lwt_Query.view_one dbh
          <:view< {x = currval $os_users_userid_seq$} >>
        in
        let userid = userid#!x in
        lwt () =
          match email with
          | Some email ->
            lwt () =
              Lwt_Query.query dbh
                <:insert< $os_emails_table$ :=
                          { email = $string:email$;
                          userid  = $int64:userid$;
                          validated = os_emails_table?validated
                          } >>
            in
            remove_preregister email
          | None ->
            Lwt.return_unit
        in
        Lwt.return userid
      )

  let update ?password ?avatar ?language ~firstname ~lastname userid =
    if password = Some "" then Lwt.fail_with "empty password"
    else
      let password = match password with
        | Some password ->
          fun _ -> as_sql_string @@ fst !pwd_crypt_ref password
        | None ->
          password_of
      in
      let avatar = match avatar with
        | Some avatar ->
          fun _ -> as_sql_string avatar
        | None ->
          avatar_of
      in
      let language = match language with
        | Some language ->
          fun _ -> as_sql_string language
        | None ->
          language_of
      in
      run_query <:update< d in $os_users_table$ :=
       { firstname = $string:firstname$;
         lastname  = $string:lastname$;
         password  = $password d$;
         avatar    = $avatar d$;
         language  = $language d$;
       } |
       d.userid = $int64:userid$
      >>

  let update_password ~userid ~password =
    if password = "" then Lwt.fail_with "empty password"
    else
      let password = as_sql_string @@ fst !pwd_crypt_ref password in
      run_query <:update< d in $os_users_table$ :=
        { password = $password$ }
        | d.userid = $int64:userid$
       >>

  let update_avatar ~userid ~avatar = run_query
    <:update< d in $os_users_table$ :=
     { avatar = $string:avatar$ }
     | d.userid = $int64:userid$
     >>

  let update_main_email ~userid ~email = run_query
    <:update< u in $os_users_table$ := { main_email = $string:email$ }
     | e in $os_emails_table$;
       e.email = $string:email$;
       u.userid = $int64:userid$;
       e.userid = u.userid;
       e.validated
    >>

  let update_language ~userid ~language = run_query
    <:update< u in $os_users_table$ := { language = $string:language$ }
     | u.userid = $int64:userid$
    >>

  let verify_password ~email ~password =
    if password = "" then Lwt.fail Empty_password
    else
      one run_view <:view<
        { t1.userid; t1.password; t2.validated }
        | t1 in $os_users_table$;
          t2 in $os_emails_table$;
          t1.userid = t2.userid;
          t2.email = $string:email$
        >>
        ~success:(fun r ->
          (* We fail for non-validated e-mails,
             because we don't want the user to log in with a non-validated
             email address. For example if the sign-up form contains
             a password field. *)
          let (userid, password', validated) =
            (r#!userid, r#?password, r#!validated)
          in
          match password' with
          | Some password' when snd !pwd_crypt_ref userid password password' ->
            if validated
            then Lwt.return userid
            else Lwt.fail Account_not_activated
          | Some _ -> Lwt.fail Wrong_password
          | _ -> Lwt.fail Password_not_set)
        ~fail:(Lwt.fail No_such_user)

  let verify_password_phone ~number ~password =
    if password = "" then Lwt.fail Empty_password
    else
      one run_view <:view<
        { t1.userid; t1.password }
        | t1 in $os_users_table$;
          t2 in $os_phones_table$;
          t1.userid = t2.userid;
          t2.number = $string:number$
        >>
        ~success:(fun r ->
          let userid = r#!userid in
          match r#?password with
          | Some password' when
              snd !pwd_crypt_ref userid password password' ->
            Lwt.return userid
          | Some _ -> Lwt.fail Wrong_password
          | _ -> Lwt.fail Password_not_set)
        ~fail:(Lwt.fail No_such_user)

  let user_of_userid userid = one run_view
    ~success:(fun r -> Lwt.return @@ tupple_of_user_sql r)
    ~fail:(Lwt.fail No_such_resource)
    <:view< t | t in $os_users_table$; t.userid = $int64:userid$ >>

  let get_actionlinkkey_info act_key =
    full_transaction_block (fun dbh ->
      one (Lwt_Query.view dbh)
        ~fail:(Lwt.fail No_such_resource)
        <:view< t
                | t in $os_action_link_table$;
                t.activationkey = $string:act_key$ >>
        ~success:(fun t ->
          let userid = t#!userid in
          let email  = t#!email in
          let validity = t#!validity in
          let autoconnect = t#!autoconnect in
          let action = match t#!action with
            | "activation" -> `AccountActivation
            | "passwordreset" -> `PasswordReset
            | c -> `Custom c in
          let data = t#!data in
          let v  = max 0L (Int64.pred validity) in
          lwt () = Lwt_Query.query dbh
              <:update< r in $os_action_link_table$ := {validity = $int64:v$} |
                        r.activationkey = $string:act_key$ >>
          in
          Lwt.return
            Os_types.Action_link_key.{
              userid;
              email;
              validity;
              action;
              data;
              autoconnect
            }
        )
    )

  let emails_of_userid userid =
    lwt r =
      run_view
        <:view< { t2.email }
                | t1 in $os_users_table$;
                t2 in $os_emails_table$;
                t1.userid = t2.userid;
                t1.userid = $int64:userid$;
        >>
    in
    Lwt.return (List.map (fun a -> a#!email) r)

  let emails_of_userid_with_status userid =
    lwt r =
      run_view
        <:view< { t2.email ; t2.validated }
                | t1 in $os_users_table$;
                t2 in $os_emails_table$;
                t1.userid = t2.userid;
                t1.userid = $int64:userid$;
        >>
    in
    Lwt.return (List.map (fun a -> a#!email, a#!validated) r)

  let email_of_userid userid = one run_view
    ~success:(fun u -> Lwt.return u#?main_email)
    ~fail:(Lwt.fail No_such_resource)
    <:view< { u.main_email }
     | u in $os_users_table$;
       u.userid = $int64:userid$
    >>

   let is_main_email ~userid ~email = one run_view
     ~success:(fun _ -> Lwt.return_true)
     ~fail:Lwt.return_false
     <:view< { u.main_email }
      | u in $os_users_table$;
        u.userid = $int64:userid$;
        u.main_email = $string:email$
     >>

  let add_email_to_user ~userid ~email = run_query
    <:insert< $os_emails_table$ :=
      { email = $string:email$;
        userid  = $int64:userid$;
        validated = os_emails_table?validated
      } >>

  let remove_email_from_user ~userid ~email =
    lwt b = is_main_email ~userid ~email in
    if b then Lwt.fail Main_email_removal_attempt else
      run_query
        <:delete< e in $os_emails_table$
         | u in $os_users_table$;
           u.userid = $int64:userid$;
           e.userid = u.userid;
           e.email = $string:email$
        >>

  let get_language userid = one run_view
    ~success:(fun u -> Lwt.return u#?language)
    ~fail:(Lwt.fail No_such_resource)
    <:view< { u.language }
     | u in $os_users_table$;
       u.userid = $int64:userid$
    >>

  let get_users ?pattern () =
    full_transaction_block (fun dbh ->
      match pattern with
      | None ->
        lwt l = Lwt_Query.view dbh <:view< r | r in $os_users_table$ >> in
        Lwt.return @@ List.map tupple_of_user_sql l
      | Some pattern ->
        let pattern = "(^"^pattern^")|(.* "^pattern^")" in
        (* Here I'm using the low-level pgocaml interface
           because macaque is missing some features
           and I cannot use pgocaml syntax extension because
           it requires the db to be created (which is impossible in a lib). *)
        let query = "
             SELECT userid, firstname, lastname, avatar, password, language
             FROM ocsigen_start.users
             WHERE
               firstname <> '' -- avoids email addresses
             AND CONCAT_WS(' ', firstname, lastname) ~* $1
         "
        in
        lwt () = PGOCaml.prepare dbh ~query () in
        lwt l = PGOCaml.execute dbh [Some pattern] () in
        lwt () = PGOCaml.close_statement dbh () in
        Lwt.return (List.map
                      (function
                        | [Some userid; Some firstname; Some lastname; avatar;
                           password; language]
                          ->
                          (PGOCaml.int64_of_string userid,
                           firstname, lastname, avatar, password <> None, language)
                        | _ -> failwith "Os_db.get_users")
                      l))

end

module Groups = struct
  let create ?description name =
    let description_o = Eliom_lib.Option.map as_sql_string description in
    run_query <:insert< $os_groups_table$ :=
                { description = of_option $description_o$;
                  name  = $string:name$;
                 groupid = os_groups_table?groupid }
               >>

  let group_of_name name = run_view_opt
    <:view< r | r in $os_groups_table$; r.name = $string:name$ >> >>= function
    | Some r -> Lwt.return (r#!groupid, r#!name, r#?description)
    | None -> Lwt.fail No_such_resource

  let add_user_in_group ~groupid ~userid = run_query
    <:insert< $os_user_groups_table$ :=
             { userid  = $int64:userid$;
               groupid = $int64:groupid$ }
    >>

  let remove_user_in_group ~groupid ~userid = run_query
    <:delete< r in $os_user_groups_table$ |
              r.groupid = $int64:groupid$;
              r.userid  = $int64:userid$
    >>

  let in_group ?dbh ~groupid ~userid () = one (run_view ?dbh)
    ~success:(fun _ -> Lwt.return_true)
    ~fail:Lwt.return_false
    <:view< t | t in $os_user_groups_table$;
                t.groupid = $int64:groupid$;
                t.userid  = $int64:userid$;
    >>

  let all () = run_query <:select< r | r in $os_groups_table$; >> >>= fun l ->
    Lwt.return @@ List.map (fun a -> (a#!groupid, a#!name, a#?description)) l

end

module Phone = struct

  let add userid number =
    without_transaction @@ fun dbh ->
    (* low-level PG interface because we want to inspect the result *)
    let query =
      "INSERT INTO ocsigen_start.phones (number, userid) VALUES ($1, $2)
       ON CONFLICT DO NOTHING
       RETURNING 0"
    in
    lwt () = PGOCaml.prepare dbh ~query () in
    lwt l  =
      PGOCaml.execute dbh [
        Some (PGOCaml.string_of_string number) ;
        Some (PGOCaml.string_of_int64 userid)
      ] ()
    in
    lwt () = PGOCaml.close_statement dbh () in
    Lwt.return (match l with | [Some _] :: _ -> true | _ -> false)

  let exists number =
    without_transaction @@ fun dbh ->
    match_lwt
      run_query
        <:select< row |
                  row in $os_phones_table$;
                  row.number = $string:number$ >>
    with
    | _ :: _ ->
      Lwt.return_true
    | [] ->
      Lwt.return_false

  let userid number =
    without_transaction @@ fun dbh ->
    match_lwt
      run_view
        <:view< { row.userid } |
                  row in $os_phones_table$;
                  row.number = $string:number$ >>
    with
    | userid :: _ ->
      Lwt.return (Some userid#!userid)
    | [] ->
      Lwt.return None

  let delete userid number =
    without_transaction @@ fun dbh -> run_query
      <:delete< row in $os_phones_table$ |
                row.userid = $int64:userid$;
                row.number = $string:number$ >>

  let get_list userid =
    without_transaction @@ fun dbh ->
    lwt l =
      run_view
        <:view< { row.number } |
                  row in $os_phones_table$;
                  row.userid = $int64:userid$ >>
    in
    Lwt.return (List.map (fun row -> row#!number) l)

end
