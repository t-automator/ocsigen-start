{shared{
  open Eliom_content.Html5.F
  open Eliom_content.Html5
}}

let app_name = "%%%PROJECT_NAME%%%"


module State_ = struct
  include Eba_default.State

  type t =
    | Default

  let states =
    [
      (Default, "default", None)
    ]

  let default () = Default
end

module Email_ = struct
  include Eba_default.Email

  let mailer = "/usr/sbin/sendmail"
end

module Groups_ = struct
  type t = %%%MODULE_NAME%%%_groups.t

  let in_group = %%%MODULE_NAME%%%_groups.in_group
end

module Page_ = struct
  include Eba_default.Page

  let title = "%%%PROJECT_NAME%%%"

  let css = [
      ["%%%PROJECT_NAME%%%.css"];
    ]

  let js = [
      ["onload.js"]
    ]

  let default_predicate : 'a 'b. 'a -> 'b -> bool Lwt.t
      = (fun _ _ -> Lwt.return true)

  let default_connected_predicate
      : 'a 'b. int64 -> 'a -> 'b -> bool Lwt.t
        = (fun _ _ _ -> Lwt.return true)

  let default_error_page
      : 'a 'b. 'a -> 'b -> exn -> Eba_shared.Page.page_content Lwt.t
        = (fun _ _ exn ->
          Lwt.return (if Ocsigen_config.get_debugmode ()
            then [p [pcdata (Printexc.to_string exn)]]
            else [p [pcdata "Error"]]))

  let default_connected_error_page
      : 'a 'b. int64 option -> 'a -> 'b -> exn
        -> Eba_shared.Page.page_content Lwt.t
          = (fun _ _ _ exn ->
            Lwt.return (if Ocsigen_config.get_debugmode ()
              then [p [pcdata (Printexc.to_string exn)]]
              else [p [pcdata "Error"]]))
end



module App = Eliom_registration.App(struct
    let application_name = app_name
  end)

module State = Eba_state.Make(State_)(App)
module Email = Eba_email.Make(Email_)
module Session = Eba_session.Make(Eba_default.Session)(Groups_)
module Page = Eba_page.Make(Page_)(Session)