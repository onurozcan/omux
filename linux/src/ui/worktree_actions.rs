//! Worktree sessions: closing (keep or delete the worktree), committing,
//! pushing for a pull request, merging, cleaning up after a merge, the pull
//! request monitor, and the branch and PR chips.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::{gio, glib};
use uuid::Uuid;

use crate::app::App;
use crate::git;
use crate::model::{SessionProvider, Worktree};
use crate::pulls::{self, CheckResult, Fetch, PrState, PullRequest};
use crate::ui::panel::background;

thread_local! {
    static PULLS: RefCell<HashMap<Uuid, PullRequest>> = RefCell::new(HashMap::new());
    static POLLING: RefCell<bool> = const { RefCell::new(false) };
}

pub fn pull(id: Uuid) -> Option<PullRequest> {
    PULLS.with(|p| p.borrow().get(&id).cloned())
}

/// A worktree session whose folder still exists.
fn worktree_of(app: &App, id: Uuid) -> Option<(Worktree, PathBuf, String)> {
    let (group, tab) = app.tab(id)?;
    let worktree = tab.worktree.clone()?;
    let dir = app.directory(&group, &tab);
    let wanted = tab
        .directory
        .as_deref()
        .map(crate::persistence::expand_tilde)?;
    (dir == wanted && dir.is_dir()).then(|| (worktree, dir, tab.name.clone()))
}

fn item(menu: &gio::Menu, label: &str, action: &str, id: Uuid) {
    let item = gio::MenuItem::new(Some(label), None);
    item.set_action_and_target_value(Some(action), Some(&id.to_string().to_variant()));
    menu.append_item(&item);
}

pub fn menu_section(app: &Rc<App>, id: Uuid) -> Option<gio::Menu> {
    let (worktree, _, _) = worktree_of(app, id)?;
    let menu = gio::Menu::new();
    match pull(id) {
        Some(pr) if pr.state == PrState::Merged => {
            item(&menu, "Delete Merged Worktree…", "app.wt-cleanup", id)
        }
        Some(pr) if pr.state == PrState::Open => item(
            &menu,
            &format!("Open Pull Request #{}", pr.number),
            "app.wt-open-pr",
            id,
        ),
        _ => item(&menu, "Create Pull Request…", "app.wt-pr", id),
    }
    item(
        &menu,
        &format!("Merge into {}", worktree.base),
        "app.wt-merge",
        id,
    );
    item(&menu, "Open Worktree in Files", "app.wt-open-folder", id);
    Some(menu)
}

pub fn install(app: &Rc<App>) {
    let add = |name: &str, f: fn(&Rc<App>, Uuid)| {
        let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
        let weak = Rc::downgrade(app);
        action.connect_activate(move |_, param| {
            let id = param
                .and_then(|p| p.str())
                .and_then(|s| Uuid::parse_str(s).ok());
            if let (Some(app), Some(id)) = (weak.upgrade(), id) {
                f(&app, id);
            }
        });
        app.gtk_app.add_action(&action);
    };
    add("wt-pr", create_pull_request);
    add("wt-merge", merge);
    add("wt-cleanup", clean_up_merged);
    add("wt-open-pr", |app, id| {
        if let Some(pr) = pull(id) {
            app.open_uri(&pr.url);
        }
    });
    add("wt-open-folder", |app, id| {
        if let Some((_, dir, _)) = worktree_of(app, id) {
            app.open_uri(&gio::File::for_path(dir).uri());
        }
    });

    // Pull requests: once shortly after launch, every 60 s, and when omux
    // becomes active.
    let weak = Rc::downgrade(app);
    glib::timeout_add_local_once(Duration::from_secs(3), move || {
        if let Some(app) = weak.upgrade() {
            poll_pulls(&app);
        }
    });
    let weak = Rc::downgrade(app);
    glib::timeout_add_local(Duration::from_secs(60), move || {
        let Some(app) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        poll_pulls(&app);
        glib::ControlFlow::Continue
    });
    let weak = Rc::downgrade(app);
    app.ui.window.connect_is_active_notify(move |w| {
        if let (true, Some(app)) = (w.is_active(), weak.upgrade()) {
            poll_pulls(&app);
        }
    });
}

/// Asks gh about each worktree session's branch, one after another.
fn poll_pulls(app: &Rc<App>) {
    if POLLING.with(|p| p.replace(true)) {
        return;
    }
    let sessions: Vec<(Uuid, PathBuf)> = app
        .all_tab_ids()
        .into_iter()
        .filter_map(|id| worktree_of(app, id).map(|(_, dir, _)| (id, dir)))
        .collect();
    let weak = Rc::downgrade(app);
    background(
        move || {
            sessions
                .into_iter()
                .map(|(id, dir)| (id, pulls::fetch(&dir)))
                .collect::<Vec<_>>()
        },
        move |results| {
            POLLING.with(|p| *p.borrow_mut() = false);
            let Some(app) = weak.upgrade() else { return };
            // Sessions no longer polled (closed, folder gone) drop their state.
            let polled: Vec<Uuid> = results.iter().map(|(id, _)| *id).collect();
            let stale: Vec<Uuid> = PULLS.with(|p| {
                let mut p = p.borrow_mut();
                let stale = p
                    .keys()
                    .filter(|id| !polled.contains(id))
                    .copied()
                    .collect();
                p.retain(|id, _| polled.contains(id));
                stale
            });
            for id in stale {
                app.refresh_session(id);
            }
            for (id, fetch) in results {
                let old = pull(id);
                match fetch {
                    Fetch::Found(pr) => {
                        if pulls::needs_attention(old.as_ref(), &pr) {
                            app.request_attention(id);
                        }
                        let changed = old.as_ref() != Some(&pr);
                        PULLS.with(|p| p.borrow_mut().insert(id, pr));
                        if changed {
                            app.refresh_session(id);
                        }
                    }
                    Fetch::None => {
                        if PULLS.with(|p| p.borrow_mut().remove(&id)).is_some() {
                            app.refresh_session(id);
                        }
                    }
                    Fetch::Unknown => {}
                }
            }
        },
    );
}

fn alert(app: &Rc<App>, heading: &str, body: &str) {
    crate::ui::dialogs::info(app, heading, body);
}

/// Close Session: worktree sessions ask whether to keep the worktree.
pub fn request_close(app: &Rc<App>, id: Uuid) {
    let Some((worktree, dir, name)) = worktree_of(app, id) else {
        app.close_tab(id);
        return;
    };
    let merged = pull(id)
        .filter(|p| p.state == PrState::Merged)
        .map(|p| p.number);
    let repo = PathBuf::from(&worktree.repo);
    let (base, branch) = (worktree.base.clone(), worktree.branch.clone());
    let weak = Rc::downgrade(app);
    background(
        move || {
            (
                git::dirty_count(&dir),
                git::ahead_count(&repo, &base, &branch),
            )
        },
        move |(dirty, ahead)| {
            let Some(app) = weak.upgrade() else { return };
            let dialog = adw::AlertDialog::new(
                Some(&git::close_title(&name)),
                Some(&git::close_text(
                    &worktree.branch,
                    &worktree.base,
                    dirty,
                    ahead,
                    merged,
                )),
            );
            dialog.add_response("cancel", "Cancel");
            dialog.add_response("keep", "Keep Worktree");
            dialog.add_response("delete", "Delete Worktree and Branch");
            dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
            dialog.set_default_response(Some("keep"));
            dialog.set_close_response("cancel");
            let weak = Rc::downgrade(&app);
            dialog.connect_response(None, move |_, response| {
                let Some(app) = weak.upgrade() else { return };
                match response {
                    "keep" => app.close_tab(id),
                    "delete" => delete_worktree(&app, id),
                    _ => {}
                }
            });
            dialog.present(Some(&app.ui.window));
        },
    );
}

/// Closes the session and deletes its worktree and branch. A Codex session
/// is stopped first so its server lets go of the folder.
fn delete_worktree(app: &Rc<App>, id: Uuid) {
    let Some((worktree, dir, _)) = worktree_of(app, id) else {
        return;
    };
    let codex = app
        .tab(id)
        .is_some_and(|(g, t)| t.resolved_provider(&g) == SessionProvider::Codex);
    let weak = Rc::downgrade(app);
    let remove = move || {
        let Some(app) = weak.upgrade() else { return };
        app.close_tab(id);
        PULLS.with(|p| p.borrow_mut().remove(&id));
        let repo = PathBuf::from(&worktree.repo);
        let branch = worktree.branch.clone();
        let weak = Rc::downgrade(&app);
        background(
            move || git::remove_worktree(&repo, &dir, &branch),
            move |result| {
                if let (Err(err), Some(app)) = (result, weak.upgrade()) {
                    alert(&app, "Couldn't delete the worktree", &err);
                }
            },
        );
    };
    if codex {
        let weak = Rc::downgrade(app);
        crate::codex::detach(id, move |result| match result {
            Ok(()) => remove(),
            Err(err) => {
                if let Some(app) = weak.upgrade() {
                    alert(&app, "Couldn't stop the Codex session", &err);
                }
            }
        });
    } else {
        remove();
    }
}

fn clean_up_merged(app: &Rc<App>, id: Uuid) {
    let Some((worktree, dir, name)) = worktree_of(app, id) else {
        return;
    };
    let number = pull(id).map(|p| p.number);
    let weak = Rc::downgrade(app);
    background(
        move || git::dirty_count(&dir),
        move |dirty| {
            let Some(app) = weak.upgrade() else { return };
            let dialog = adw::AlertDialog::new(
                Some(&git::cleanup_title(&name)),
                Some(&git::cleanup_text(&worktree.branch, number, dirty)),
            );
            dialog.add_response("cancel", "Cancel");
            dialog.add_response("delete", "Delete Worktree and Branch");
            dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
            dialog.set_close_response("cancel");
            let weak = Rc::downgrade(&app);
            dialog.connect_response(Some("delete"), move |_, _| {
                if let Some(app) = weak.upgrade() {
                    delete_worktree(&app, id);
                }
            });
            dialog.present(Some(&app.ui.window));
        },
    );
}

/// Commits uncommitted files first (asking for a message), since they
/// aren't part of a merge or pull request; then runs `next`.
fn commit_if_needed(app: &Rc<App>, id: Uuid, next: impl FnOnce(Rc<App>) + 'static) {
    let Some((worktree, dir, name)) = worktree_of(app, id) else {
        return;
    };
    let weak = Rc::downgrade(app);
    let check_dir = dir.clone();
    background(
        move || git::dirty_count(&check_dir),
        move |dirty| {
            let Some(app) = weak.upgrade() else { return };
            if dirty == 0 {
                next(app);
                return;
            }
            let dialog = adw::AlertDialog::new(
                Some(&git::commit_title(dirty)),
                Some(&git::commit_text(&worktree.branch)),
            );
            let entry = gtk::Entry::new();
            entry.set_placeholder_text(Some("Commit message"));
            entry.set_text(&name);
            entry.set_activates_default(true);
            dialog.set_extra_child(Some(&entry));
            dialog.add_response("cancel", "Cancel");
            dialog.add_response("commit", "Commit");
            dialog.set_response_appearance("commit", adw::ResponseAppearance::Suggested);
            dialog.set_default_response(Some("commit"));
            dialog.set_close_response("cancel");
            let next = RefCell::new(Some(next));
            let weak = Rc::downgrade(&app);
            dialog.connect_response(Some("commit"), move |_, _| {
                let Some(app) = weak.upgrade() else { return };
                let text = entry.text().trim().to_string();
                let message = if text.is_empty() { name.clone() } else { text };
                let dir = dir.clone();
                let Some(next) = next.borrow_mut().take() else {
                    return;
                };
                let weak = Rc::downgrade(&app);
                background(
                    move || git::commit_all(&dir, &message),
                    move |result| {
                        let Some(app) = weak.upgrade() else { return };
                        match result {
                            Ok(()) => next(app),
                            Err(err) => alert(&app, "Couldn't commit", &err),
                        }
                    },
                );
            });
            dialog.present(Some(&app.ui.window));
        },
    );
}

/// Pushes the branch and opens GitHub's compare page into the base branch.
pub fn create_pull_request(app: &Rc<App>, id: Uuid) {
    commit_if_needed(app, id, move |app| {
        let Some((worktree, dir, _)) = worktree_of(&app, id) else {
            return;
        };
        let branch = worktree.branch.clone();
        crate::ui::changes::set_activity(id, Some(format!("Pushing {branch}…")));
        let weak = Rc::downgrade(&app);
        background(
            move || {
                git::push(&dir, &worktree.branch)?;
                Ok::<_, String>(git::compare_url(
                    &git::remote_url(&dir),
                    &worktree.base,
                    &worktree.branch,
                ))
            },
            move |result| {
                crate::ui::changes::set_activity(id, None);
                let Some(app) = weak.upgrade() else { return };
                match result {
                    Ok(Some(url)) => app.open_uri(&url),
                    Ok(None) => alert(
                        &app,
                        &format!("Pushed “{branch}”"),
                        "The remote isn't on GitHub, so open the pull request on your host.",
                    ),
                    Err(err) => alert(&app, &format!("Couldn't push “{branch}”"), &err),
                }
            },
        );
    });
}

pub fn merge(app: &Rc<App>, id: Uuid) {
    commit_if_needed(app, id, move |app| {
        let Some((worktree, _, _)) = worktree_of(&app, id) else {
            return;
        };
        let (base, branch) = (worktree.base.clone(), worktree.branch.clone());
        crate::ui::changes::set_activity(id, Some(format!("Merging into {base}…")));
        let weak = Rc::downgrade(&app);
        background(
            move || git::merge(Path::new(&worktree.repo), &worktree.base, &worktree.branch),
            move |result| {
                crate::ui::changes::set_activity(id, None);
                let Some(app) = weak.upgrade() else { return };
                match result {
                    Ok(output) => alert(&app, &format!("Merged “{branch}” into “{base}”"), &output),
                    Err(err) => alert(&app, &format!("Couldn't merge “{branch}”"), &err),
                }
            },
        );
    });
}

fn chip_dot(color: &str) -> gtk::Box {
    let dot = crate::ui::sidebar::dot();
    let color = match color {
        "secondary" => None,
        other => Some(other),
    };
    crate::ui::sidebar::set_dot(&dot, color);
    dot
}

/// `● #N` with the PR's color, plus Delete Worktree once it's merged.
pub fn sidebar_extras(app: &App, id: Uuid, container: &gtk::Box) {
    let Some(pr) = pull(id) else { return };
    if worktree_of(app, id).is_none() {
        return;
    }
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let badge = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    badge.append(&chip_dot(pr.color()));
    let label = gtk::Label::new(Some(&format!("#{}", pr.number)));
    label.add_css_class("omux-status");
    badge.append(&label);
    badge.set_tooltip_text(Some(&format!("#{} · {}", pr.number, pr.summary())));
    row.append(&badge);
    if pr.state == PrState::Merged {
        let delete = gtk::Button::with_label("Delete Worktree");
        delete.add_css_class("omux-small");
        delete.set_tooltip_text(Some(
            "The pull request was merged. Close this session and delete its worktree and branch.",
        ));
        delete.set_action_name(Some("app.wt-cleanup"));
        delete.set_action_target_value(Some(&id.to_string().to_variant()));
        row.append(&delete);
    }
    container.append(&row);
}

/// The PR chip (with its checks) and the branch chip in the session header.
pub fn header_chips(app: &App, id: Uuid, container: &gtk::Box) {
    let Some((worktree, _, _)) = worktree_of(app, id) else {
        return;
    };
    if let Some(pr) = pull(id) {
        let content = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        content.append(&gtk::Label::new(Some(&format!("⇡ #{}", pr.number))));
        content.append(&chip_dot(pr.color()));
        let summary = gtk::Label::new(Some(pr.summary()));
        summary.add_css_class("omux-status");
        content.append(&summary);
        let button = gtk::MenuButton::builder().child(&content).build();
        button.add_css_class("flat");
        button.set_create_popup_func(move |button| {
            if let Some(pr) = pull(id) {
                button.set_popover(Some(&pr_popover(id, &pr)));
            }
        });
        container.append(&button);
    }
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 5);
    content.append(&gtk::Label::new(Some("⎇")));
    content.append(&gtk::Label::new(Some(&worktree.branch)));
    if let Some((added, removed)) = crate::ui::changes::totals(id) {
        let totals = gtk::Label::new(Some(&format!("+{added} −{removed}")));
        totals.add_css_class("omux-status");
        content.append(&totals);
    }
    let branch = gtk::Button::new();
    branch.set_child(Some(&content));
    branch.add_css_class("flat");
    branch.set_tooltip_text(Some(&format!(
        "Changes on {} since {} (Ctrl+Alt+2)",
        worktree.branch, worktree.base
    )));
    branch.set_action_name(Some("app.panel-tab"));
    branch.set_action_target_value(Some(&"changes".to_variant()));
    container.append(&branch);
}

fn pr_popover(id: Uuid, pr: &PullRequest) -> gtk::Popover {
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 8);
    vbox.set_margin_start(12);
    vbox.set_margin_end(12);
    vbox.set_margin_top(10);
    vbox.set_margin_bottom(10);
    vbox.set_size_request(320, -1);
    let title = gtk::Label::new(Some(&pr.title));
    title.add_css_class("heading");
    title.set_wrap(true);
    title.set_lines(2);
    title.set_xalign(0.0);
    vbox.append(&title);
    let facts = gtk::Label::new(Some(&pr.facts()));
    facts.add_css_class("omux-status");
    facts.set_xalign(0.0);
    vbox.append(&facts);
    if pr.checks.is_empty() {
        let none = gtk::Label::new(Some("No checks"));
        none.add_css_class("omux-status");
        none.set_xalign(0.0);
        vbox.append(&none);
    } else {
        let list = gtk::Box::new(gtk::Orientation::Vertical, 4);
        for check in &pr.checks {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            let (color, text) = match check.result {
                CheckResult::Passed => ("green", "passed"),
                CheckResult::Failed => ("red", "failed"),
                CheckResult::Pending => ("blue", "running"),
                CheckResult::Skipped => ("secondary", "skipped"),
            };
            row.append(&chip_dot(color));
            let name = gtk::Label::new(Some(&check.name));
            name.set_hexpand(true);
            name.set_xalign(0.0);
            name.set_ellipsize(gtk::pango::EllipsizeMode::End);
            row.append(&name);
            let state = gtk::Label::new(Some(text));
            state.add_css_class("omux-status");
            row.append(&state);
            if let Some(url) = check.url.clone() {
                let click = gtk::GestureClick::new();
                click.connect_released(move |_, _, _, _| {
                    let _ = gio::AppInfo::launch_default_for_uri(&url, gio::AppLaunchContext::NONE);
                });
                row.add_controller(click);
            }
            list.append(&row);
        }
        let scroller = gtk::ScrolledWindow::builder()
            .child(&list)
            .max_content_height(260)
            .propagate_natural_height(true)
            .build();
        vbox.append(&scroller);
    }
    let popover = gtk::Popover::new();
    let open = gtk::Button::with_label("Open on GitHub");
    let url = pr.url.clone();
    let pop = popover.downgrade();
    open.connect_clicked(move |_| {
        let _ = gio::AppInfo::launch_default_for_uri(&url, gio::AppLaunchContext::NONE);
        if let Some(p) = pop.upgrade() {
            p.popdown();
        }
    });
    vbox.append(&open);
    if pr.state == PrState::Merged {
        let delete = gtk::Button::with_label("Delete Worktree and Branch…");
        delete.add_css_class("destructive-action");
        delete.set_action_name(Some("app.wt-cleanup"));
        delete.set_action_target_value(Some(&id.to_string().to_variant()));
        let pop = popover.downgrade();
        delete.connect_clicked(move |_| {
            if let Some(p) = pop.upgrade() {
                p.popdown();
            }
        });
        vbox.append(&delete);
    }
    popover.set_child(Some(&vbox));
    popover
}

/// Create PR (with Merge into <base> in its menu), or the push/merge in progress.
pub fn changes_footer(app: &Rc<App>, id: Uuid, activity: Option<String>) -> Option<gtk::Widget> {
    let (worktree, _, _) = worktree_of(app, id)?;
    if let Some(activity) = activity {
        let hbox = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        let spinner = gtk::Spinner::new();
        spinner.start();
        hbox.append(&spinner);
        let label = gtk::Label::new(Some(&activity));
        label.add_css_class("omux-status");
        hbox.append(&label);
        return Some(hbox.upcast());
    }
    let menu = gio::Menu::new();
    let item = gio::MenuItem::new(Some(&format!("Merge into {}", worktree.base)), None);
    item.set_action_and_target_value(Some("app.wt-merge"), Some(&id.to_string().to_variant()));
    menu.append_item(&item);
    let button = adw::SplitButton::new();
    button.set_label("Create PR");
    button.set_menu_model(Some(&menu));
    button.add_css_class("omux-small");
    button.set_tooltip_text(Some(&format!(
        "Push {} and open a pull request into {}",
        worktree.branch, worktree.base
    )));
    button.set_action_name(Some("app.wt-pr"));
    button.set_action_target_value(Some(&id.to_string().to_variant()));
    Some(button.upcast())
}
