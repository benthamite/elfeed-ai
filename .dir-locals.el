((org-mode . ((eval . (add-hook 'after-save-hook
                                (lambda ()
                                  (when (equal (file-name-nondirectory buffer-file-name)
                                               "README.org")
                                    (require 'ox-texinfo)
                                    (let ((inhibit-message t))
                                      (org-texinfo-export-to-info))))
                                nil t)))))
