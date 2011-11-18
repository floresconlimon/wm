#!/usr/local/bin/sbcl --script
;;; Used to be the most simple window manager on earth. It is a fork
;;; from the lisp version of tinywm.

;;; Load swank and make a server
(require 'asdf)
(asdf:load-system :swank)
(swank:create-server :port 4005 :dont-close t)

;;; Load CLX and make a package
(asdf:load-system :clx)
(defpackage :most.simple.wm
  (:use :common-lisp :xlib :sb-ext))
(in-package :most.simple.wm)

(defvar *display* (open-default-display))
(defvar *root* (screen-root (display-default-screen *display*)))
(defparameter *windows* nil "List of managed and mapped windows.")
(defparameter *last* nil "Last focused window.")
(defparameter *curr* nil "Current focused window.")

(defun mods (l) (butlast l))
(defun kchar (l) (car (last l)))
(defun compile-shortcut (l)
  "Compile a shortcut into a (state . code) form. For
example: (compile-shortcut '(:control #\t)) -> (4 . 44). Works also
for mouse button."
  (let ((k (kchar l))
        (state (apply #'make-state-mask (mods l))))
    (if (characterp k)
        (let ((c (keysym->keycodes *display* (car (character->keysyms k)))))
          (cons state c))
        (cons state k))))
(defun state (l) (car l))
(defun code (l) (cdr l))
(defun sc= (sc state code) (and (= (code sc) code) (= (state sc) state)))

(defparameter *shortcuts*
  (list (cons (compile-shortcut '(:shift #\q)) 'quit))
  "Shortcuts alist initialized with the quit command.")

(defmacro defshortcut (key &body body)
  "Define a new shortcut in *shortcuts* alist. The key in this alist
  is in (state . code) form and the associated value is a lambda
  without argument."
  (let ((sc (gensym)))
    `(let ((,sc (compile-shortcut ',key)))
       (pushnew (cons ,sc #'(lambda () ,@body)) *shortcuts* :test #'equal :key #'car))))

(defgeneric focus (window &key))

(defmethod focus :before (window &key)
  (unless (null window)
    (unless (win= window *curr*) (setf *last* *curr*))
    (setf *curr* window)))

(defmethod focus ((window window) &key &allow-other-keys)
  (when (eql (window-map-state window) :viewable)
    (setf (window-priority window) :above)
    (set-input-focus *display* window :pointer-root)))

(defmethod focus ((window list) &key (warp-p t))
  (unless (null window)
    (dolist (w window)
      (when (eql (window-map-state w) :viewable)
        (setf (window-priority w) :above)))
    (set-input-focus *display* :pointer-root :pointer-root)
    (let ((focus (first window)))
      (setf (window-priority focus) :above)
      (when warp-p
        (warp-pointer focus
                      (truncate (drawable-width focus) 2)
                      (truncate (drawable-height focus) 2))))))

(defmethod focus :after (window &key) (display-finish-output *display*))

(defmethod win= ((a window) (b window)) (window-equal a b))
(defmethod win= ((a list) (b window)) (loop for w in a thereis (window-equal w b)))
(defmethod win= ((a window) (b list)) (loop for w in b thereis (window-equal w a)))
(defmethod win= ((a list) (b list)) (loop for w in a thereis (win= w b)))

(defun next (&optional (way #'1+) (window *curr*))
  (when *windows*
    (let* ((nw (or (position window *windows* :test #'win=) 0))
           (n (length *windows*))
           (next (mod (funcall way nw) n)))
      (nth next *windows*))))

(defparameter *groupers* (list
                          #'(lambda (w)
                              (multiple-value-bind (name class) (get-wm-class w)
                                (string= class "Idl")))
                          #'(lambda (w)
                              (multiple-value-bind (name class) (get-wm-class w)
                                (string= class "MuPDF"))))
  "List of predicates against which windows are grouped")

(defun plus (window)
  "Add window to the list of managed windows. Take care of grouping
and don't add window already in the list."
  (let ((grouper (find-if #'(lambda (f) (funcall f window)) *groupers*)))
    (labels ((radd (item list pred test)
               (cond ((and (null list) (functionp pred))
                      (list (list item)))
                     ((null list) (list item))
                     (t (let ((hd (car list))
                              (tl (cdr list)))
                          (cond ((funcall test hd item) list)
                                ((and (listp hd)
                                      (functionp pred)
                                      (funcall pred (car hd)))
                                 (cons (cons item hd) tl))
                                (t (cons hd (radd item tl pred test)))))))))
      (setf *windows* (radd window *windows* grouper #'win=))
      (find window *windows* :test #'win=))))

(defun rrem (item list &key (test #'eql))
  "Recursive remove."
  (unless (null list)
    (let* ((hd (car list))
           (tl (cdr list))
           (rtl (rrem item tl :test test)))
      (cond ((listp hd)
             (let ((rhd (rrem item hd :test test)))
               (if rhd
                   (cons rhd rtl)
                   rtl)))
            ((funcall test item hd) rtl)
            (t (cons hd rtl))))))

(defun minus (window)
  "House keeping when window is unmapped. Returns the window to be
focused or nil if nothing has to be done."
  (when (member window *windows* :test #'win=)
    (setf *windows* (rrem window *windows* :test #'window-equal))
    (let (res)
      (when (win= window *curr*)
        (let ((ncurr (find-if #'(lambda (w) (win= w *curr*)) *windows*)))
          (cond (ncurr (setf *curr* ncurr
                             res nil))
                (t (setf *curr* (next #'1+ *last*)
                         res *last*)))))
      (when (win= window *last*)
        (let ((nlast (find-if #'(lambda (w) (win= w *last*)) *windows*)))
          (setf *last* (if nlast nlast (next #'1+ *curr*))
                res nil)))
      (when (win= *curr* *last*) (setf *last* (setf res nil)))
      res)))

(defmacro defror (command)
  "Define a raise or run command."
  (let ((win (gensym))
        (cmdstr (gensym)))
    `(defun ,command ()
       (let* ((,cmdstr (string-downcase (string ',command)))
              (,win (find-if #'(lambda (w)
                                 (string-equal
                                  ,cmdstr
                                  (second (multiple-value-list (get-wm-class w)))))
                             *windows*)))
         (if ,win
             (focus ,win)
             (run-program ,cmdstr nil :wait nil :search t))))))
(defror emacs)
(defror xxxterm)
(defror firefox)

(defun send-message (window type &rest data)
  (send-event window :client-message nil :window window
              :type type :format 32 :data data))

;;; Apps in path
(defun split-string (string &optional (character #\Space))
    "Returns a list of substrings of string
divided by ONE space each.
Note: Two consecutive spaces will be seen as
if there were an empty string between them."
    (loop for i = 0 then (1+ j)
          as j = (position character string :start i)
          collect (subseq string i j)
          while j))

(defun execp (pathname)
  "Return T if the pathname describes an executable file."
  (let ((filename (namestring pathname)))
    (and (or (pathname-name pathname)
             (pathname-type pathname))
         (sb-unix:unix-access filename sb-unix:x_ok))))

(defparameter *apps*
  (let ((paths (split-string (posix-getenv "PATH") #\:)))
    (loop for path in paths
       append (loop for file in (directory (merge-pathnames
                                            (make-pathname :name :wild :type :wild)
                                            (concatenate 'string path "/")))
                   when (execp file) collect (file-namestring file)))))

;;; Modifier keypress avoidance code
(defvar *mods-code* (multiple-value-call #'append (modifier-mapping *display*)))

(defun is-modifier (keycode)
  "Return t if keycode is a modifier"
  (find keycode *mods-code* :test #'eql))

;;; App launcher
(defparameter *abort* (compile-shortcut '(:control #\g)))
(defparameter *this* (compile-shortcut '(#\Return))
  "Validate THIS app even if it is a prefix of more than one.")

(defun single (list) (and (consp list) (null (cdr list))))

(defun one-char ()
  (event-case (*display*)
    (:key-press (code state)
                (cond ((is-modifier code) (one-char))
                      ((sc= *abort* state code) *abort*)
                      ((sc= *this* state code) *this*)
                      (t (keycode->character *display* code state))))))

(defun recapp (pos list)
  (cond ((null list))
        ((single list)
         (run-program (car list) nil :wait nil :search t))
        (t (let ((char (one-char)))
             (etypecase char
               (character
                (let ((sublist (remove-if #'(lambda (str)
                                              (or (>= pos (length str))
                                                  (char/= (elt str pos) char))) list)))
                  (recapp (1+ pos) sublist)))
               (cons
                (cond ((sc= char (state *abort*) (code *abort*)))
                      ((sc= char (state *this*) (code *this*))
                       (let ((sublist (remove-if #'(lambda (str) (/= (length str) pos))
                                                 list)))
                         (recapp (1+ pos) sublist))))))))))

(defun app ()
  (grab-keyboard *root*)
  (unwind-protect (recapp 0 *apps*)
    (ungrab-keyboard *display*)))

;;; Mouse shorcuts
(defparameter *move* (compile-shortcut '(:mod-1 1)) "Mouse button to move a window")
(defparameter *resize* (compile-shortcut '(:mod-1 3)) "Mouse button to resize a window")
(defparameter *close* (compile-shortcut '(:control :mod-1 2))
  "Mouse button to close a window")

;;; Key shortcuts
(defparameter *prefix* (compile-shortcut '(:control #\t)) "Prefix for shortcuts")
(defshortcut (#\c) (run-program "xterm" nil :wait nil :search t))
(defshortcut (#\e) (emacs))
(defshortcut (#\w) (xxxterm))
(defshortcut (:control #\l) (run-program "xlock" nil :wait nil :search t))
(defshortcut (:mod-1 #\e) (run-program "envi" nil :wait nil :search t))
(defshortcut (#\n) (focus (next)))
(defshortcut (#\p) (focus (next #'1-)))
(defshortcut (:control #\n) (focus (next)))
(defshortcut (:control #\p) (focus (next #'1-)))
(defshortcut (:control #\t) (focus *last*))
(defshortcut (#\a) (app))

(defun send-prefix ()
  (let ((focus (input-focus *display*)))
    (when (win= focus *curr*)
      (send-event focus :key-press (make-event-mask :key-press)
                  :window focus
                  :code (code *prefix*)
                  :state (state *prefix*)))))
(defshortcut (#\t) (send-prefix))

;;; Main
(defun main ()
  (let (last-button last-x last-y waiting-shortcut)

    ;; Grab prefix and mouse buttons on root
    (grab-key *root* (code *prefix*) :modifiers (state *prefix*))
    (grab-button *root* (code *move*) '(:button-press) :modifiers (state *move*))
    (grab-button *root* (code *resize*) '(:button-press) :modifiers (state *resize*))
    (grab-button *root* (code *close*) '(:button-press) :modifiers (state *close*))

    ;; Populate list of windows
    (loop for w in (query-tree *root*) do
         (when (and (eql (window-map-state w) :viewable)
                    (eql (window-override-redirect w) :off))
           (plus w)))

    (intern-atom *display* :_motif_wm_hints)
    (setf (window-event-mask *root*) '(:substructure-notify))

    (unwind-protect
         (loop do
              (event-case
               (*display* :discard-p t)
               (:key-press
                (code state)
                (unless (is-modifier code)
                  (cond (waiting-shortcut
                         (let ((entry (assoc-if
                                       #'(lambda (sc) (sc= sc state code)) *shortcuts*)))
                           (when entry
                             (let ((fn (cdr entry)))
                               (cond ((functionp fn) (funcall fn))
                                     ((eq fn 'quit) (loop-finish))))))
                         (ungrab-keyboard *display*)
                         (setf waiting-shortcut nil))
                        ((sc= *prefix* state code)
                         (grab-keyboard *root*)
                         (setf waiting-shortcut t)))))
               (:button-press
                (code state child)
                (when (and child (eql (window-override-redirect child) :off))
                  (cond ((sc= *close* state code)
                         (send-message child :WM_PROTOCOLS
                                       (intern-atom *display* :WM_DELETE_WINDOW)))
                        (t
                         (setf last-button code)
                         (focus (find child *windows* :test #'win=) :warp-p nil)
                         (grab-pointer child '(:pointer-motion :button-release))
                         (when (sc= *resize* state code)
                           (warp-pointer child (drawable-width child)
                                         (drawable-height child)))
                         (let ((lst (multiple-value-list (query-pointer *root*))))
                           (setf last-x (sixth lst)
                                 last-y (seventh lst)))))))
               (:motion-notify
                (event-window root-x root-y)
                (cond ((= last-button (code *move*))
                       (let ((delta-x (- root-x last-x))
                             (delta-y (- root-y last-y)))
                         (incf (drawable-x event-window) delta-x)
                         (incf (drawable-y event-window) delta-y)
                         (incf last-x delta-x)
                         (incf last-y delta-y)))
                      ((= last-button (code *resize*))
                       (let ((new-w (max 1 (- root-x (drawable-x event-window))))
                             (new-h (max 1 (- root-y (drawable-y event-window)))))
                         (setf (drawable-width event-window) new-w
                               (drawable-height event-window) new-h)))))
               (:button-release () (ungrab-pointer *display*))
               (:map-notify
                (window override-redirect-p)
                (unless override-redirect-p
                  (focus (plus window))))
               (:unmap-notify
                (window)
                (focus (minus window)))))
      (ungrab-button *root* (code *move*) :modifiers (state *move*))
      (ungrab-button *root* (code *resize*) :modifiers (state *resize*))
      (ungrab-button *root* (code *close*) :modifiers (state *close*))
      (ungrab-key *root* (code *prefix*) :modifiers (state *prefix*))
      (close-display *display*))))

(main)
