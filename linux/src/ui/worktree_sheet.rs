//! New Session in Worktree: the session works on its own branch in its own
//! folder (`<repo>.worktrees/<branch>`), so sessions don't touch each other's
//! files.

use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;

use adw::prelude::*;
use uuid::Uuid;

use crate::app::App;
use crate::git;
use crate::model::{SessionProvider, TabItem, Worktree};
use crate::ui::panel::background;

const AGENTS: [(Option<SessionProvider>, &str); 3] = [
    (None, "Project default"),
    (Some(SessionProvider::Claude), "Claude Code"),
    (Some(SessionProvider::Codex), "Codex"),
];

pub fn present(app: &Rc<App>, group_id: Uuid, provider: Option<SessionProvider>) {
    let Some(gi) = app.group_index(group_id) else {
        return;
    };
    let group = app.ws.borrow().groups[gi].clone();
    let project_dir = group
        .directory
        .as_deref()
        .map(crate::persistence::expand_tilde);

    let page = adw::PreferencesPage::new();
    page.set_description(
        "The session works on its own branch in its own folder, so sessions don't touch each other's files.",
    );
    let main = adw::PreferencesGroup::new();
    let name = adw::EntryRow::new();
    name.set_title("Name");
    name.set_text(&format!("Session {}", group.tabs.len() + 1));
    main.add(&name);
    let agent = adw::ComboRow::new();
    agent.set_title("Agent");
    agent.set_model(Some(&gtk::StringList::new(&AGENTS.map(|(_, l)| l))));
    agent.set_selected(AGENTS.iter().position(|(p, _)| *p == provider).unwrap_or(0) as u32);
    main.add(&agent);
    page.add(&main);

    let git_group = adw::PreferencesGroup::new();
    let branch = adw::EntryRow::new();
    branch.set_title("Branch");
    branch.add_css_class("omux-mono");
    branch.set_text(&git::slug(&name.text()));
    git_group.add(&branch);
    let base = adw::ComboRow::new();
    base.set_title("From");
    git_group.add(&base);
    let folder = adw::ActionRow::new();
    folder.set_title("Folder");
    folder.set_subtitle_selectable(true);
    git_group.add(&folder);
    let setup = adw::EntryRow::new();
    setup.set_title("Setup (cp \"$OMUX_REPO/.env\" . && npm install)");
    setup.add_css_class("omux-mono");
    setup.set_text(&group.worktree_setup);
    git_group.add(&setup);
    git_group.set_description(Some(
        "Runs in each new worktree before the session starts, and only starts it if setup succeeds. \
         $OMUX_REPO is the main checkout, for copying files Git ignores. Saved with the project.",
    ));
    page.add(&git_group);

    let options = adw::PreferencesGroup::new();
    let remember = adw::SwitchRow::new();
    remember.set_title(&format!("Use worktrees for new sessions in {}", group.name));
    remember.set_active(group.use_worktrees);
    options.add(&remember);
    let error = gtk::Label::new(None);
    error.add_css_class("error");
    error.set_wrap(true);
    error.set_xalign(0.0);
    error.set_visible(false);
    options.add(&error);
    page.add(&options);

    let dialog = adw::Dialog::new();
    dialog.set_title("New Session in Worktree");
    dialog.set_content_width(480);
    let bar = adw::HeaderBar::new();
    bar.set_show_end_title_buttons(false);
    bar.set_show_start_title_buttons(false);
    let cancel = gtk::Button::with_label("Cancel");
    let d = dialog.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(d) = d.upgrade() {
            d.close();
        }
    });
    bar.pack_start(&cancel);
    let create = gtk::Button::with_label("Create");
    create.add_css_class("suggested-action");
    create.set_sensitive(false);
    bar.pack_end(&create);
    let spinner = gtk::Spinner::new();
    bar.pack_end(&spinner);
    let view = adw::ToolbarView::new();
    view.add_top_bar(&bar);
    view.set_content(Some(&page));
    dialog.set_child(Some(&view));

    // The setup command and the preference are saved as they change, even
    // if the sheet is cancelled, as on the Mac.
    let weak = Rc::downgrade(app);
    setup.connect_changed(move |row| {
        let text = row.text().trim().to_string();
        if let Some(app) = weak.upgrade() {
            app.update_group(group_id, |g| g.worktree_setup = text);
        }
    });
    let weak = Rc::downgrade(app);
    remember.connect_active_notify(move |row| {
        let on = row.is_active();
        if let Some(app) = weak.upgrade() {
            app.update_group(group_id, |g| g.use_worktrees = on);
        }
    });

    // The branch follows the name until the user edits it.
    let branch_edited = Rc::new(Cell::new(false));
    let syncing = Rc::new(Cell::new(false));
    let (b, s) = (branch.clone(), syncing.clone());
    let edited = branch_edited.clone();
    name.connect_changed(move |row| {
        if !edited.get() {
            s.set(true);
            b.set_text(&git::slug(&row.text()));
            s.set(false);
        }
    });
    let (s, edited) = (syncing.clone(), branch_edited.clone());
    branch.connect_changed(move |_| {
        if !s.get() {
            edited.set(true);
        }
    });

    let repo: Rc<std::cell::RefCell<Option<PathBuf>>> = Rc::default();
    let branches: Rc<std::cell::RefCell<Vec<String>>> = Rc::default();
    let validate = {
        let (name, branch, base, folder, create, repo, branches) = (
            name.clone(),
            branch.clone(),
            base.clone(),
            folder.clone(),
            create.clone(),
            repo.clone(),
            branches.clone(),
        );
        move || {
            let branch_text = branch.text().trim().to_string();
            if let Some(repo) = repo.borrow().as_ref() {
                folder.set_subtitle(&git::worktree_path(repo, &branch_text).display().to_string());
            }
            let has_base = branches.borrow().get(base.selected() as usize).is_some();
            create.set_sensitive(
                repo.borrow().is_some()
                    && !name.text().trim().is_empty()
                    && !branch_text.is_empty()
                    && !branch_text.contains(' ')
                    && has_base,
            );
        }
    };
    for row in [&name, &branch] {
        let v = validate.clone();
        row.connect_changed(move |_| v());
    }

    // Find the repository and its branches off the main thread.
    let (e, v, base_row, repo_cell, branch_cell) = (
        error.clone(),
        validate.clone(),
        base.clone(),
        repo.clone(),
        branches.clone(),
    );
    background(
        move || {
            let dir = project_dir?;
            let top = git::top_level(&dir)?;
            let current = git::current_branch(&top);
            Some((top.clone(), git::local_branches(&top), current))
        },
        move |found| match found {
            Some((top, list, current)) => {
                let selected = current
                    .and_then(|c| list.iter().position(|b| *b == c))
                    .unwrap_or(0);
                let labels: Vec<&str> = list.iter().map(String::as_str).collect();
                base_row.set_model(Some(&gtk::StringList::new(&labels)));
                base_row.set_selected(selected as u32);
                *branch_cell.borrow_mut() = list;
                *repo_cell.borrow_mut() = Some(top);
                v();
            }
            None => {
                e.set_text(&match &group.directory {
                    Some(dir) => format!("{dir} isn't a Git repository."),
                    None => "This project has no folder.".into(),
                });
                e.add_css_class("warning");
                e.set_visible(true);
            }
        },
    );

    let weak = Rc::downgrade(app);
    let d = dialog.downgrade();
    create.connect_clicked(move |button| {
        let Some(app) = weak.upgrade() else { return };
        let Some(top) = repo.borrow().clone() else {
            return;
        };
        let Some(base_branch) = branches.borrow().get(base.selected() as usize).cloned() else {
            return;
        };
        let branch_name = branch.text().trim().to_string();
        let session_name = name.text().trim().to_string();
        let choice = AGENTS[agent.selected() as usize].0;
        let setup_text = setup.text().trim().to_string();
        let use_worktrees = remember.is_active();
        let path = git::worktree_path(&top, &branch_name);
        button.set_sensitive(false);
        spinner.start();
        let (error, spinner, d) = (error.clone(), spinner.clone(), d.clone());
        let weak = Rc::downgrade(&app);
        let (b, p) = (branch_name.clone(), path.clone());
        let top_for_add = top.clone();
        let base_for_add = base_branch.clone();
        let button = button.clone();
        background(
            move || git::add_worktree(&top_for_add, &p, &b, &base_for_add),
            move |result| {
                spinner.stop();
                let Some(app) = weak.upgrade() else { return };
                if let Err(err) = result {
                    error.set_text(&err);
                    error.remove_css_class("warning");
                    error.set_visible(true);
                    button.set_sensitive(true);
                    return;
                }
                app.update_group(group_id, |g| {
                    g.worktree_setup = setup_text.clone();
                    g.use_worktrees = use_worktrees;
                });
                let mut tab = TabItem::new(session_name);
                tab.directory = Some(path.display().to_string());
                tab.worktree = Some(Worktree {
                    branch: branch_name,
                    base: base_branch,
                    repo: top.display().to_string(),
                });
                if let Some(provider) = choice {
                    tab.provider = Some(provider);
                    tab.command = Some(provider.command().to_string());
                }
                app.add_session(group_id, tab, None, Some(&setup_text));
                if let Some(d) = d.upgrade() {
                    d.close();
                }
            },
        );
    });
    dialog.present(Some(&app.ui.window));
}
